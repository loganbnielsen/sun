#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/threads.h>
#include <caml/unixsupport.h>
#include <librdkafka/rdkafka.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdint.h>
#include <stddef.h>

/* ------------------------------------------------------------------ */
/* Custom block ops and finalizers                                      */
/* ------------------------------------------------------------------ */

/* The GC finalizer is a no-op: Kafka_producer.close() calls ocaml_rd_kafka_destroy
   which nulls this pointer before destroying. Any non-null pointer here means
   close() was not called — we accept the resource leak rather than risk blocking
   the GC (rd_kafka_destroy can block for seconds waiting for broker I/O). */
static void kafka_handle_finalize(value v) {
  *((rd_kafka_t **)Data_custom_val(v)) = NULL;
}

static void kafka_conf_finalize(value v) {
  rd_kafka_conf_t *conf = *((rd_kafka_conf_t **)Data_custom_val(v));
  if (conf) rd_kafka_conf_destroy(conf);
}

static void kafka_topic_finalize(value v) {
  rd_kafka_topic_t *rkt = *((rd_kafka_topic_t **)Data_custom_val(v));
  if (rkt) rd_kafka_topic_destroy(rkt);
}

static struct custom_operations kafka_handle_ops = {
  "kafka_handle", kafka_handle_finalize,
  custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default,
  custom_compare_ext_default, custom_fixed_length_default
};

static struct custom_operations kafka_conf_ops = {
  "kafka_conf", kafka_conf_finalize,
  custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default,
  custom_compare_ext_default, custom_fixed_length_default
};

static struct custom_operations kafka_topic_ops = {
  "kafka_topic", kafka_topic_finalize,
  custom_compare_default, custom_hash_default,
  custom_serialize_default, custom_deserialize_default,
  custom_compare_ext_default, custom_fixed_length_default
};

/* ------------------------------------------------------------------ */
/* Delivery callback — writes a (correlation_id, err_code) pair to a  */
/* pipe. Runs on the librdkafka background thread; no OCaml runtime   */
/* access needed.                                                       */
/* ------------------------------------------------------------------ */

typedef struct {
  int64_t  correlation_id;
  int32_t  err;
} delivery_result_t;

_Static_assert(offsetof(delivery_result_t, correlation_id) == 0,
               "correlation_id offset mismatch — OCaml reads uint64 at byte 0");
_Static_assert(offsetof(delivery_result_t, err) == 8,
               "err offset mismatch — OCaml reads uint32 at byte 8");

static void delivery_cb(rd_kafka_t *rk,
                        const rd_kafka_message_t *msg,
                        void *opaque)
{
  if (!msg->_private) return;   /* no correlation id — fire-and-forget */
  int write_fd = *((int *)opaque);
  delivery_result_t r;
  r.correlation_id = (int64_t)(uintptr_t)msg->_private;
  r.err            = (int32_t)msg->err;
  /* write is async-signal-safe and thread-safe */
  ssize_t n;
  do { n = write(write_fd, &r, sizeof(r)); } while (n < 0 && errno == EINTR);
}

/* ------------------------------------------------------------------ */
/* conf_new                                                             */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_rd_kafka_conf_new(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(v);
  rd_kafka_conf_t *conf = rd_kafka_conf_new();
  v = caml_alloc_custom(&kafka_conf_ops, sizeof(rd_kafka_conf_t *), 0, 1);
  *((rd_kafka_conf_t **)Data_custom_val(v)) = conf;
  CAMLreturn(v);
}

/* ------------------------------------------------------------------ */
/* conf_set : kafka_conf -> string -> string -> (unit, string) result  */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_rd_kafka_conf_set(value conf_v, value key_v, value val_v) {
  CAMLparam3(conf_v, key_v, val_v);
  CAMLlocal2(result, err_str);
  rd_kafka_conf_t *conf = *((rd_kafka_conf_t **)Data_custom_val(conf_v));
  char errstr[512];
  rd_kafka_conf_res_t res = rd_kafka_conf_set(
    conf,
    String_val(key_v),
    String_val(val_v),
    errstr, sizeof(errstr)
  );
  if (res == RD_KAFKA_CONF_OK) {
    result = caml_alloc(1, 0); /* Ok () */
    Store_field(result, 0, Val_unit);
  } else {
    err_str = caml_copy_string(errstr);
    result = caml_alloc(1, 1); /* Error s */
    Store_field(result, 0, err_str);
  }
  CAMLreturn(result);
}

/* ------------------------------------------------------------------ */
/* kafka_new — also installs delivery callback and sets opaque fd      */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_rd_kafka_new(value type_v, value conf_v, value write_fd_v) {
  CAMLparam3(type_v, conf_v, write_fd_v);
  CAMLlocal2(result, handle_v);

  /* steal the conf out of the custom block so rd_kafka_new owns it */
  rd_kafka_conf_t *conf = *((rd_kafka_conf_t **)Data_custom_val(conf_v));
  *((rd_kafka_conf_t **)Data_custom_val(conf_v)) = NULL; /* prevent double-free */

  rd_kafka_type_t rk_type = (Int_val(type_v) == 0)
    ? RD_KAFKA_PRODUCER
    : RD_KAFKA_CONSUMER;

  /* Install delivery callback for producers */
  int *fd_ptr = NULL;
  if (rk_type == RD_KAFKA_PRODUCER) {
    fd_ptr = malloc(sizeof(int));
    *fd_ptr = Int_val(write_fd_v);
    rd_kafka_conf_set_dr_msg_cb(conf, delivery_cb);
    rd_kafka_conf_set_opaque(conf, fd_ptr);
  }

  char errstr[512];
  rd_kafka_t *rk = rd_kafka_new(rk_type, conf, errstr, sizeof(errstr));
  if (!rk) {
    free(fd_ptr); /* librdkafka destroyed conf but not our opaque; free(NULL) is a no-op */
    CAMLlocal1(err_str);
    err_str = caml_copy_string(errstr);
    result = caml_alloc(1, 1); /* Error s */
    Store_field(result, 0, err_str);
  } else {
    handle_v = caml_alloc_custom(&kafka_handle_ops, sizeof(rd_kafka_t *), 0, 1);
    *((rd_kafka_t **)Data_custom_val(handle_v)) = rk;
    result = caml_alloc(1, 0); /* Ok handle */
    Store_field(result, 0, handle_v);
  }
  CAMLreturn(result);
}

/* ------------------------------------------------------------------ */
/* subscribe (consumer)                                                 */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_rd_kafka_subscribe(value handle_v, value topics_v) {
  CAMLparam2(handle_v, topics_v);
  CAMLlocal2(result, head);

  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  rd_kafka_topic_partition_list_t *tpl = rd_kafka_topic_partition_list_new(4);

  value lst = topics_v;
  while (lst != Val_emptylist) {
    head = Field(lst, 0);
    rd_kafka_topic_partition_list_add(tpl, String_val(head), RD_KAFKA_PARTITION_UA);
    lst = Field(lst, 1);
  }

  rd_kafka_resp_err_t err = rd_kafka_subscribe(rk, tpl);
  rd_kafka_topic_partition_list_destroy(tpl);

  if (err == RD_KAFKA_RESP_ERR_NO_ERROR) {
    result = caml_alloc(1, 0);
    Store_field(result, 0, Val_unit);
  } else {
    CAMLlocal1(err_v);
    err_v = caml_copy_string(rd_kafka_err2str(err));
    result = caml_alloc(1, 1);
    Store_field(result, 0, err_v);
  }
  CAMLreturn(result);
}

/* ------------------------------------------------------------------ */
/* consumer_poll — returns a message or None                            */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_rd_kafka_consumer_poll(value handle_v, value timeout_v) {
  CAMLparam2(handle_v, timeout_v);
  CAMLlocal3(msg_rec, some_v, key_opt);
  CAMLlocal3(hdr_list, hdr_cell, hdr_pair);
  CAMLlocal3(topic_v, part_v, offset_v);
  CAMLlocal2(val_bytes, ts_opt);
  CAMLlocal2(hdr_name_v, hdr_val_v);

  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  int timeout_ms = Int_val(timeout_v);          /* read before releasing lock */
  caml_release_runtime_system();
  rd_kafka_message_t *msg = rd_kafka_consumer_poll(rk, timeout_ms);
  caml_acquire_runtime_system();
  /* all OCaml allocation below — safe after re-acquiring */

  if (!msg)
    CAMLreturn(Val_int(0)); /* None — timeout */

  if (msg->err) {
    /* RD_KAFKA_RESP_ERR__PARTITION_EOF is informational; all errors → None */
    rd_kafka_message_destroy(msg);
    CAMLreturn(Val_int(0)); /* None */
  }

  /* Build a 7-tuple: (topic, partition, offset, key_opt, value, timestamp_opt, headers) */

  topic_v  = caml_copy_string(rd_kafka_topic_name(msg->rkt));
  part_v   = caml_copy_int32((int32_t)msg->partition);
  offset_v = caml_copy_int64((int64_t)msg->offset);

  if (msg->key && msg->key_len > 0) {
    CAMLlocal1(key_bytes);
    key_bytes = caml_alloc_string(msg->key_len);
    memcpy(Bytes_val(key_bytes), msg->key, msg->key_len);
    key_opt = caml_alloc(1, 0);   /* Some bytes */
    Store_field(key_opt, 0, key_bytes);
  } else {
    key_opt = Val_int(0);          /* None */
  }

  val_bytes = caml_alloc_string(msg->len);
  if (msg->len > 0) memcpy(Bytes_val(val_bytes), msg->payload, msg->len);

  rd_kafka_timestamp_type_t tstype;
  int64_t ts = rd_kafka_message_timestamp(msg, &tstype);
  if (tstype != RD_KAFKA_TIMESTAMP_NOT_AVAILABLE) {
    CAMLlocal1(ts_v);
    ts_v   = caml_copy_int64(ts);
    ts_opt = caml_alloc(1, 0);     /* Some int64 */
    Store_field(ts_opt, 0, ts_v);
  } else {
    ts_opt = Val_int(0);           /* None */
  }

  /* Extract headers before destroy — ownership belongs to msg */
  hdr_list = Val_emptylist;
  rd_kafka_headers_t *hdrs = NULL;
  if (rd_kafka_message_headers(msg, &hdrs) == RD_KAFKA_RESP_ERR_NO_ERROR && hdrs) {
    size_t hdr_count = rd_kafka_header_cnt(hdrs);
    /* Iterate backwards so the resulting OCaml list preserves header order */
    while (hdr_count > 0) {
      hdr_count--;
      const char *name;
      const void *hval;
      size_t hval_size;
      if (rd_kafka_header_get_all(hdrs, hdr_count, &name, &hval, &hval_size)
          == RD_KAFKA_RESP_ERR_NO_ERROR) {
        hdr_name_v = caml_copy_string(name);
        hdr_val_v  = caml_alloc_string(hval_size);
        if (hval_size > 0 && hval)
          memcpy(Bytes_val(hdr_val_v), hval, hval_size);
        hdr_pair = caml_alloc_tuple(2);
        Store_field(hdr_pair, 0, hdr_name_v);
        Store_field(hdr_pair, 1, hdr_val_v);
        hdr_cell = caml_alloc_tuple(2);   /* cons cell */
        Store_field(hdr_cell, 0, hdr_pair);
        Store_field(hdr_cell, 1, hdr_list);
        hdr_list = hdr_cell;
      }
    }
  }

  rd_kafka_message_destroy(msg);

  msg_rec = caml_alloc_tuple(7);
  Store_field(msg_rec, 0, topic_v);
  Store_field(msg_rec, 1, part_v);
  Store_field(msg_rec, 2, offset_v);
  Store_field(msg_rec, 3, key_opt);
  Store_field(msg_rec, 4, val_bytes);
  Store_field(msg_rec, 5, ts_opt);
  Store_field(msg_rec, 6, hdr_list);

  some_v = caml_alloc(1, 0);      /* Some msg_rec */
  Store_field(some_v, 0, msg_rec);
  CAMLreturn(some_v);
}

/* ------------------------------------------------------------------ */
/* topic_new                                                            */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_rd_kafka_topic_new(value handle_v, value name_v) {
  CAMLparam2(handle_v, name_v);
  CAMLlocal1(topic_v);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  rd_kafka_topic_t *rkt = rd_kafka_topic_new(rk, String_val(name_v), NULL);
  topic_v = caml_alloc_custom(&kafka_topic_ops, sizeof(rd_kafka_topic_t *), 0, 1);
  *((rd_kafka_topic_t **)Data_custom_val(topic_v)) = rkt;
  CAMLreturn(topic_v);
}

/* ------------------------------------------------------------------ */
/* produce : kafka_topic -> partition -> value -> key_opt -> correlation_id -> (unit,int) result */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_rd_kafka_produce(value topic_v, value part_v,
                                      value val_v,  value key_opt_v,
                                      value corr_v)
{
  CAMLparam5(topic_v, part_v, val_v, key_opt_v, corr_v);
  CAMLlocal1(result);

  rd_kafka_topic_t *rkt = *((rd_kafka_topic_t **)Data_custom_val(topic_v));
  int32_t partition     = Int32_val(part_v);

  void *payload     = Bytes_val(val_v);
  size_t payload_sz = caml_string_length(val_v);

  void *key     = NULL;
  size_t key_sz = 0;
  if (key_opt_v != Val_int(0)) { /* Some bytes */
    value kb = Field(key_opt_v, 0);
    key    = Bytes_val(kb);
    key_sz = caml_string_length(kb);
  }

  /* correlation_id 0 means fire-and-forget; non-zero means awaited */
  void *msg_opaque = (void *)(uintptr_t)(int64_t)Int64_val(corr_v);

  int rc = rd_kafka_produce(
    rkt, partition,
    RD_KAFKA_MSG_F_COPY,
    payload, payload_sz,
    key, key_sz,
    msg_opaque
  );

  if (rc == 0) {
    result = caml_alloc(1, 0); Store_field(result, 0, Val_unit);
  } else {
    result = caml_alloc(1, 1); Store_field(result, 0, Val_int(errno));
  }
  CAMLreturn(result);
}

/* ------------------------------------------------------------------ */
/* enable_queue_events : kafka_handle -> write_fd -> unit              */
/* Registers write_fd with the librdkafka main queue so that           */
/* one byte (0x01) is written to write_fd whenever the queue           */
/* transitions from empty to non-empty.  The OCaml poll_fiber          */
/* sleeps on the matching read end and calls poll(rk,0) on wake-up.   */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_kafka_enable_queue_events(value handle_v, value write_fd_v) {
  CAMLparam2(handle_v, write_fd_v);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  int write_fd = Int_val(write_fd_v);
  rd_kafka_queue_t *q = rd_kafka_queue_get_main(rk);
  /* static: librdkafka holds this pointer until deregistered; stack memory
     would become dangling once this function returns. */
  static const char payload = 1;
  rd_kafka_queue_io_event_enable(q, write_fd, &payload, sizeof(payload));
  rd_kafka_queue_destroy(q);
  CAMLreturn(Val_unit);
}

/* ------------------------------------------------------------------ */
/* disable_queue_events : kafka_handle -> unit                         */
/* Clears the io-event callback from the main queue so librdkafka      */
/* stops writing to the pipe write-fd.  Call before closing the pipe   */
/* to prevent stale-fd writes after the fd is recycled by Eio.         */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_kafka_disable_queue_events(value handle_v) {
  CAMLparam1(handle_v);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  rd_kafka_queue_t *q = rd_kafka_queue_get_main(rk);
  rd_kafka_queue_io_event_enable(q, -1, NULL, 0);
  rd_kafka_queue_destroy(q);
  CAMLreturn(Val_unit);
}

/* ------------------------------------------------------------------ */
/* poll : kafka_handle -> timeout_ms -> int (events served)            */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_rd_kafka_poll(value handle_v, value timeout_v) {
  CAMLparam2(handle_v, timeout_v);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  int timeout_ms = Int_val(timeout_v);          /* read before releasing lock */
  caml_release_runtime_system();
  int n = rd_kafka_poll(rk, timeout_ms);
  caml_acquire_runtime_system();
  CAMLreturn(Val_int(n));
}

/* ------------------------------------------------------------------ */
/* err2str                                                              */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_rd_kafka_err2str(value code_v) {
  CAMLparam1(code_v);
  CAMLreturn(caml_copy_string(rd_kafka_err2str((rd_kafka_resp_err_t)Int_val(code_v))));
}

/* ------------------------------------------------------------------ */
/* flush                                                                */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_rd_kafka_flush(value handle_v, value timeout_v) {
  CAMLparam2(handle_v, timeout_v);
  CAMLlocal1(result);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  int timeout_ms = Int_val(timeout_v);   /* read before releasing lock */
  caml_release_runtime_system();
  rd_kafka_resp_err_t err = rd_kafka_flush(rk, timeout_ms);
  caml_acquire_runtime_system();
  if (err == RD_KAFKA_RESP_ERR_NO_ERROR) {
    result = caml_alloc(1, 0); Store_field(result, 0, Val_unit);
  } else {
    result = caml_alloc(1, 1); Store_field(result, 0, Val_int((int)err));
  }
  CAMLreturn(result);
}

/* Explicit destroy: nulls the OCaml pointer (preventing finalizer double-destroy)
   and calls rd_kafka_destroy with the domain lock released. */
CAMLprim value ocaml_rd_kafka_destroy(value handle_v) {
  CAMLparam1(handle_v);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  if (rk) {
    *((rd_kafka_t **)Data_custom_val(handle_v)) = NULL;
    caml_release_runtime_system();
    rd_kafka_destroy(rk);
    caml_acquire_runtime_system();
  }
  CAMLreturn(Val_unit);
}

/* ------------------------------------------------------------------ */
/* consumer_close                                                       */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_rd_kafka_consumer_close(value handle_v) {
  CAMLparam1(handle_v);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  if (rk) {
    caml_release_runtime_system();
    rd_kafka_consumer_close(rk);
    caml_acquire_runtime_system();
  }
  CAMLreturn(Val_unit);
}

/* ------------------------------------------------------------------ */
/* assignment_count                                                     */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_rd_kafka_assignment_count(value handle_v) {
  CAMLparam1(handle_v);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  rd_kafka_topic_partition_list_t *parts = NULL;
  int count = 0;
  if (rk && rd_kafka_assignment(rk, &parts) == RD_KAFKA_RESP_ERR_NO_ERROR) {
    if (parts) { count = parts->cnt; rd_kafka_topic_partition_list_destroy(parts); }
  }
  CAMLreturn(Val_int(count));
}

/* ------------------------------------------------------------------ */
/* create_topic (librdkafka admin API)                                 */
/* ------------------------------------------------------------------ */

/* Creates a topic using librdkafka's built-in admin API on an existing
   producer handle. Releases the OCaml domain lock while polling for the
   broker response. Returns 0 on success (treating TOPIC_ALREADY_EXISTS as
   success), or a librdkafka error code on failure. */
CAMLprim value ocaml_rd_kafka_create_topic(value handle_v, value topic_v,
                                            value partitions_v, value replicas_v)
{
  CAMLparam4(handle_v, topic_v, partitions_v, replicas_v);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  int partitions = Int_val(partitions_v);
  int replicas   = Int_val(replicas_v);

  /* Copy topic name to C heap before releasing the OCaml runtime. */
  size_t topic_len = caml_string_length(topic_v);
  char *topic_copy = (char *)malloc(topic_len + 1);
  if (!topic_copy) {
    CAMLreturn(Val_int(RD_KAFKA_RESP_ERR__FAIL));
  }
  memcpy(topic_copy, String_val(topic_v), topic_len + 1);

  caml_release_runtime_system();

  char errstr[512];
  rd_kafka_NewTopic_t *new_topic =
    rd_kafka_NewTopic_new(topic_copy, partitions, replicas, errstr, sizeof(errstr));
  free(topic_copy);

  if (!new_topic) {
    caml_acquire_runtime_system();
    CAMLreturn(Val_int(RD_KAFKA_RESP_ERR__INVALID_ARG));
  }

  rd_kafka_AdminOptions_t *options =
    rd_kafka_AdminOptions_new(rk, RD_KAFKA_ADMIN_OP_CREATETOPICS);
  rd_kafka_queue_t *queue = rd_kafka_queue_new(rk);

  rd_kafka_CreateTopics(rk, &new_topic, 1, options, queue);

  rd_kafka_event_t *event = rd_kafka_queue_poll(queue, 5000 /* ms */);

  int err_code = RD_KAFKA_RESP_ERR__TIMED_OUT;
  if (event) {
    const rd_kafka_CreateTopics_result_t *result =
      rd_kafka_event_CreateTopics_result(event);
    if (result) {
      size_t result_cnt = 0;
      const rd_kafka_topic_result_t **results =
        rd_kafka_CreateTopics_result_topics(result, &result_cnt);
      if (results && result_cnt > 0) {
        err_code = rd_kafka_topic_result_error(results[0]);
        if (err_code == RD_KAFKA_RESP_ERR_TOPIC_ALREADY_EXISTS)
          err_code = 0;
      } else {
        err_code = 0;
      }
    }
    rd_kafka_event_destroy(event);
  }

  rd_kafka_queue_destroy(queue);
  rd_kafka_AdminOptions_destroy(options);
  rd_kafka_NewTopic_destroy(new_topic);

  caml_acquire_runtime_system();
  CAMLreturn(Val_int(err_code));
}

/* ------------------------------------------------------------------ */
/* commit_message                                                       */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_rd_kafka_commit_message(value handle_v, value topic_v,
                                              value part_v,  value offset_v,
                                              value async_v)
{
  CAMLparam5(handle_v, topic_v, part_v, offset_v, async_v);
  CAMLlocal1(result);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  int async = Bool_val(async_v); /* read before any release */

  rd_kafka_resp_err_t err;
  /* Empty topic is the sentinel for commit_all (commit current assignment). */
  if (caml_string_length(topic_v) == 0) {
    caml_release_runtime_system();
    err = rd_kafka_commit(rk, NULL, async);
    caml_acquire_runtime_system();
  } else {
    rd_kafka_topic_partition_list_t *tpl = rd_kafka_topic_partition_list_new(1);
    rd_kafka_topic_partition_t *tp = rd_kafka_topic_partition_list_add(
      tpl, String_val(topic_v), Int32_val(part_v)
    );
    tp->offset = Int64_val(offset_v) + 1; /* commit next offset */
    caml_release_runtime_system();
    err = rd_kafka_commit(rk, tpl, async);
    caml_acquire_runtime_system();
    rd_kafka_topic_partition_list_destroy(tpl);
  }

  if (err == RD_KAFKA_RESP_ERR_NO_ERROR) {
    result = caml_alloc(1, 0); Store_field(result, 0, Val_unit);
  } else {
    result = caml_alloc(1, 1); Store_field(result, 0, Val_int((int)err));
  }
  CAMLreturn(result);
}

/* ------------------------------------------------------------------ */
/* Transactional API                                                    */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_rd_kafka_init_transactions(value handle_v, value timeout_v) {
  CAMLparam2(handle_v, timeout_v);
  CAMLlocal1(result);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  int timeout_ms = Int_val(timeout_v);
  caml_release_runtime_system();
  rd_kafka_error_t *err = rd_kafka_init_transactions(rk, timeout_ms);
  caml_acquire_runtime_system();
  if (!err) {
    result = caml_alloc(1, 0); Store_field(result, 0, Val_unit);
  } else {
    int code = (int)rd_kafka_error_code(err);
    rd_kafka_error_destroy(err);
    result = caml_alloc(1, 1); Store_field(result, 0, Val_int(code));
  }
  CAMLreturn(result);
}

CAMLprim value ocaml_rd_kafka_begin_transaction(value handle_v) {
  CAMLparam1(handle_v);
  CAMLlocal1(result);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  caml_release_runtime_system();
  rd_kafka_error_t *err = rd_kafka_begin_transaction(rk);
  caml_acquire_runtime_system();
  if (!err) {
    result = caml_alloc(1, 0); Store_field(result, 0, Val_unit);
  } else {
    int code = (int)rd_kafka_error_code(err);
    rd_kafka_error_destroy(err);
    result = caml_alloc(1, 1); Store_field(result, 0, Val_int(code));
  }
  CAMLreturn(result);
}

CAMLprim value ocaml_rd_kafka_commit_transaction(value handle_v, value timeout_v) {
  CAMLparam2(handle_v, timeout_v);
  CAMLlocal1(result);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  int timeout_ms = Int_val(timeout_v);
  caml_release_runtime_system();
  rd_kafka_error_t *err = rd_kafka_commit_transaction(rk, timeout_ms);
  caml_acquire_runtime_system();
  if (!err) {
    result = caml_alloc(1, 0); Store_field(result, 0, Val_unit);
  } else {
    int code = (int)rd_kafka_error_code(err);
    rd_kafka_error_destroy(err);
    result = caml_alloc(1, 1); Store_field(result, 0, Val_int(code));
  }
  CAMLreturn(result);
}

CAMLprim value ocaml_rd_kafka_abort_transaction(value handle_v, value timeout_v) {
  CAMLparam2(handle_v, timeout_v);
  CAMLlocal1(result);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  int timeout_ms = Int_val(timeout_v);
  caml_release_runtime_system();
  rd_kafka_error_t *err = rd_kafka_abort_transaction(rk, timeout_ms);
  caml_acquire_runtime_system();
  if (!err) {
    result = caml_alloc(1, 0); Store_field(result, 0, Val_unit);
  } else {
    int code = (int)rd_kafka_error_code(err);
    rd_kafka_error_destroy(err);
    result = caml_alloc(1, 1); Store_field(result, 0, Val_int(code));
  }
  CAMLreturn(result);
}

CAMLprim value ocaml_rd_kafka_send_offsets_to_transaction(
  value prod_v, value cons_v, value timeout_v)
{
  CAMLparam3(prod_v, cons_v, timeout_v);
  CAMLlocal1(result);
  rd_kafka_t *prod = *((rd_kafka_t **)Data_custom_val(prod_v));
  rd_kafka_t *cons = *((rd_kafka_t **)Data_custom_val(cons_v));
  int timeout_ms = Int_val(timeout_v);

  /* Read current assignment and group metadata while holding the runtime lock,
     then release before the blocking broker round-trip. */
  rd_kafka_topic_partition_list_t *offsets = NULL;
  rd_kafka_assignment(cons, &offsets);
  rd_kafka_consumer_group_metadata_t *cgmd = rd_kafka_consumer_group_metadata(cons);

  caml_release_runtime_system();
  rd_kafka_error_t *err = rd_kafka_send_offsets_to_transaction(
    prod, offsets, cgmd, timeout_ms
  );
  caml_acquire_runtime_system();

  rd_kafka_consumer_group_metadata_destroy(cgmd);
  if (offsets) rd_kafka_topic_partition_list_destroy(offsets);

  if (!err) {
    result = caml_alloc(1, 0); Store_field(result, 0, Val_unit);
  } else {
    int code = (int)rd_kafka_error_code(err);
    rd_kafka_error_destroy(err);
    result = caml_alloc(1, 1); Store_field(result, 0, Val_int(code));
  }
  CAMLreturn(result);
}

/* ------------------------------------------------------------------ */
/* delivery_sizeof — returns sizeof(delivery_result_t) so OCaml can   */
/* allocate a Cstruct buffer of exactly the right size.                */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_kafka_delivery_sizeof(value unit) {
  CAMLparam1(unit);
  CAMLreturn(Val_int(sizeof(delivery_result_t)));
}

/* ------------------------------------------------------------------ */
/* pipe_create — creates a non-blocking pipe, returns (read_fd,        */
/* write_fd) as a pair of ints                                          */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_kafka_pipe_create(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(pair);
  int fds[2];
  if (pipe(fds) < 0) caml_failwith("kafka_pipe_create: pipe() failed");
  pair = caml_alloc_tuple(2);
  Store_field(pair, 0, Val_int(fds[0]));
  Store_field(pair, 1, Val_int(fds[1]));
  CAMLreturn(pair);
}

/* ------------------------------------------------------------------ */
/* produce_v — produce with header support via rd_kafka_producev        */
/*                                                                      */
/* Takes kafka_handle (not topic handle) + topic_name string so that   */
/* rd_kafka_producev can be used. Headers are passed as an OCaml list  */
/* of (name, value) string pairs and transferred to librdkafka.        */
/* 7 args → requires both native and bytecode entrypoints.             */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_rd_kafka_produce_v(
  value handle_v, value topic_v, value part_v,
  value val_v,   value key_opt_v, value corr_v, value headers_v)
{
  CAMLparam5(handle_v, topic_v, part_v, val_v, key_opt_v);
  CAMLxparam2(corr_v, headers_v);
  CAMLlocal2(result, hd);

  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  int32_t partition = Int32_val(part_v);

  void *payload     = Bytes_val(val_v);
  size_t payload_sz = caml_string_length(val_v);

  void *key     = NULL;
  size_t key_sz = 0;
  if (key_opt_v != Val_int(0)) {
    value kb = Field(key_opt_v, 0);
    key    = Bytes_val(kb);
    key_sz = caml_string_length(kb);
  }

  void *msg_opaque = (void *)(uintptr_t)(int64_t)Int64_val(corr_v);

  /* Build librdkafka headers from the OCaml (string * string) list.
     rd_kafka_producev transfers ownership on success; we destroy on error. */
  rd_kafka_headers_t *hdrs = NULL;
  value lst = headers_v;
  while (lst != Val_emptylist) {
    hd = Field(lst, 0);
    if (!hdrs) hdrs = rd_kafka_headers_new(4);
    const char *hname  = String_val(Field(hd, 0));
    const void *hval   = String_val(Field(hd, 1));
    size_t hval_size   = caml_string_length(Field(hd, 1));
    rd_kafka_header_add(hdrs, hname, -1, hval, hval_size);
    lst = Field(lst, 1);
  }

  rd_kafka_resp_err_t err;
  if (hdrs) {
    err = rd_kafka_producev(rk,
      RD_KAFKA_V_TOPIC(String_val(topic_v)),
      RD_KAFKA_V_MSGFLAGS(RD_KAFKA_MSG_F_COPY),
      RD_KAFKA_V_PARTITION(partition),
      RD_KAFKA_V_VALUE(payload, payload_sz),
      RD_KAFKA_V_KEY(key, key_sz),
      RD_KAFKA_V_HEADERS(hdrs),
      RD_KAFKA_V_OPAQUE(msg_opaque),
      RD_KAFKA_V_END);
    if (err != RD_KAFKA_RESP_ERR_NO_ERROR)
      rd_kafka_headers_destroy(hdrs);  /* ownership not transferred on error */
  } else {
    err = rd_kafka_producev(rk,
      RD_KAFKA_V_TOPIC(String_val(topic_v)),
      RD_KAFKA_V_MSGFLAGS(RD_KAFKA_MSG_F_COPY),
      RD_KAFKA_V_PARTITION(partition),
      RD_KAFKA_V_VALUE(payload, payload_sz),
      RD_KAFKA_V_KEY(key, key_sz),
      RD_KAFKA_V_OPAQUE(msg_opaque),
      RD_KAFKA_V_END);
  }

  if (err == RD_KAFKA_RESP_ERR_NO_ERROR) {
    result = caml_alloc(1, 0); Store_field(result, 0, Val_unit);
  } else {
    result = caml_alloc(1, 1); Store_field(result, 0, Val_int((int)err));
  }
  CAMLreturn(result);
}

/* Bytecode trampoline required for 6+ argument externals */
CAMLprim value ocaml_rd_kafka_produce_v_bytecode(value *argv, int argc) {
  (void)argc;
  return ocaml_rd_kafka_produce_v(
    argv[0], argv[1], argv[2], argv[3], argv[4], argv[5], argv[6]);
}

/* ------------------------------------------------------------------ */
/* pipe_read_delivery — reads one delivery_result_t from read_fd.      */
/* Returns (correlation_id, err_code) pair.                             */
/* ------------------------------------------------------------------ */

CAMLprim value ocaml_kafka_read_delivery(value fd_v) {
  CAMLparam1(fd_v);
  CAMLlocal1(pair);
  delivery_result_t r;
  ssize_t n;
  do { n = read(Int_val(fd_v), &r, sizeof(r)); } while (n < 0 && errno == EINTR);
  if (n != sizeof(r)) caml_failwith("kafka_read_delivery: short read");
  pair = caml_alloc_tuple(2);
  Store_field(pair, 0, caml_copy_int64(r.correlation_id));
  Store_field(pair, 1, Val_int((int)r.err));
  CAMLreturn(pair);
}

/* ------------------------------------------------------------------ */
/* pause_partition / resume_partition                                   */
/*                                                                      */
/* Local operations: modify the consumer handle's fetch state for one  */
/* partition without any broker round-trip, so no lock release needed. */
/* Used by consume_partitioned to halt delivery to a partition while    */
/* its fiber sleeps during retry backoff.                               */
/* ------------------------------------------------------------------ */

value ocaml_rd_kafka_pause_partition(value handle_v, value topic_v, value part_v)
{
  CAMLparam3(handle_v, topic_v, part_v);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  if (!rk) CAMLreturn(Val_unit);
  rd_kafka_topic_partition_list_t *tpl = rd_kafka_topic_partition_list_new(1);
  rd_kafka_topic_partition_list_add(tpl, String_val(topic_v),
                                    (int32_t)Int32_val(part_v));
  rd_kafka_pause_partitions(rk, tpl);
  rd_kafka_topic_partition_list_destroy(tpl);
  CAMLreturn(Val_unit);
}

value ocaml_rd_kafka_resume_partition(value handle_v, value topic_v, value part_v)
{
  CAMLparam3(handle_v, topic_v, part_v);
  rd_kafka_t *rk = *((rd_kafka_t **)Data_custom_val(handle_v));
  if (!rk) CAMLreturn(Val_unit);
  rd_kafka_topic_partition_list_t *tpl = rd_kafka_topic_partition_list_new(1);
  rd_kafka_topic_partition_list_add(tpl, String_val(topic_v),
                                    (int32_t)Int32_val(part_v));
  rd_kafka_resume_partitions(rk, tpl);
  rd_kafka_topic_partition_list_destroy(tpl);
  CAMLreturn(Val_unit);
}
