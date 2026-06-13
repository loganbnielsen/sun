type t =
  | Unknown
  | Offset_out_of_range
  | Invalid_msg
  | Unknown_topic_or_part
  | Invalid_msg_size
  | Leader_not_available
  | Not_leader_for_partition
  | Request_timed_out
  | Broker_not_available
  | Replica_not_available
  | Msg_size_too_large
  | Stale_ctrl_epoch
  | Offset_metadata_too_large
  | Network_exception
  | Coordinator_load_in_progress
  | Coordinator_not_available
  | Not_coordinator
  | Topic_exception
  | Record_list_too_large
  | Not_enough_replicas
  | Not_enough_replicas_after_append
  | Invalid_required_acks
  | Illegal_generation
  | Inconsistent_group_protocol
  | Invalid_group_id
  | Unknown_member_id
  | Invalid_session_timeout
  | Rebalance_in_progress
  | Invalid_commit_offset_size
  | Topic_authorization_failed
  | Group_authorization_failed
  | Cluster_authorization_failed
  | Invalid_timestamp
  | Unsupported_sasl_mechanism
  | Illegal_sasl_state
  | Unsupported_version
  | Topic_already_exists
  | Invalid_partitions
  | Invalid_replication_factor
  | Invalid_replica_assignment
  | Invalid_config
  | Not_controller
  | Invalid_request
  | Unsupported_for_message_format
  | Policy_violation
  | Out_of_order_sequence_number
  | Duplicate_sequence_number
  | Invalid_producer_epoch
  | Invalid_txn_state
  | Invalid_producer_id_mapping
  | Invalid_transaction_timeout
  | Concurrent_transactions
  | Transaction_coordinator_fenced
  | Transactional_id_authorization_failed
  | Security_disabled
  | Operation_not_attempted
  | Kafka_storage_error
  | Log_dir_not_found
  | Sasl_authentication_failed
  | Unknown_producer_id
  | Reassignment_in_progress
  | No_error
  | Begin
  | Bad_msg
  | Bad_compression
  | Destroy
  | Fail
  | Transport
  | Crit_sys_resource
  | Resolve
  | Msg_timed_out
  | Partition_eof
  | Unknown_partition
  | Fs
  | Unknown_topic
  | All_brokers_down
  | Invalid_arg
  | Timed_out
  | Queue_full
  | Isr_insuff
  | Node_update
  | Ssl
  | Wait_coord
  | Unknown_group
  | In_progress
  | Prev_in_progress
  | Existing_subscription
  | Assign_partitions
  | Revoke_partitions
  | Conflict
  | State
  | Unknown_protocol
  | Not_implemented
  | Authentication
  | No_offset
  | Outdated
  | Timed_out_queue
  | Unsupported_feature
  | Wait_cache
  | Intr
  | Key_serialization
  | Value_serialization
  | Key_deserialization
  | Value_deserialization
  | Partial
  | Read_only
  | Noent
  | Underflow
  | Invalid_type
  | Retry
  | Purge_queue
  | Purge_inflight
  | Fatal
  | Inconsistent
  | Gapless_guarantees
  | Max_poll_exceeded
  | Unknown_broker
  | Not_configured
  | Fenced
  | Application
  | Err_unknown of int

(* Single source-of-truth mapping between variants and rd_kafka_resp_err_t codes.
   Positive codes = Kafka protocol errors; negative = librdkafka internal errors. *)
let table : (t * int) list = [
  No_error,                              0;
  Offset_out_of_range,                   1;
  Invalid_msg,                           2;
  Unknown_topic_or_part,                 3;
  Invalid_msg_size,                      4;
  Leader_not_available,                  5;
  Not_leader_for_partition,              6;
  Request_timed_out,                     7;
  Broker_not_available,                  8;
  Replica_not_available,                 9;
  Msg_size_too_large,                   10;
  Stale_ctrl_epoch,                     11;
  Offset_metadata_too_large,            12;
  Network_exception,                    13;
  Coordinator_load_in_progress,         14;
  Coordinator_not_available,            15;
  Not_coordinator,                      16;
  Topic_exception,                      17;
  Record_list_too_large,                18;
  Not_enough_replicas,                  19;
  Not_enough_replicas_after_append,     20;
  Invalid_required_acks,                21;
  Illegal_generation,                   22;
  Inconsistent_group_protocol,          23;
  Invalid_group_id,                     24;
  Unknown_member_id,                    25;
  Invalid_session_timeout,              26;
  Rebalance_in_progress,                27;
  Invalid_commit_offset_size,           28;
  Topic_authorization_failed,           29;
  Group_authorization_failed,           30;
  Cluster_authorization_failed,         31;
  Invalid_timestamp,                    32;
  Unsupported_sasl_mechanism,           33;
  Illegal_sasl_state,                   34;
  Unsupported_version,                  35;
  Topic_already_exists,                 36;
  Invalid_partitions,                   37;
  Invalid_replication_factor,           38;
  Invalid_replica_assignment,           39;
  Invalid_config,                       40;
  Not_controller,                       41;
  Invalid_request,                      42;
  Unsupported_for_message_format,       43;
  Policy_violation,                     44;
  Out_of_order_sequence_number,         45;
  Duplicate_sequence_number,            46;
  Invalid_producer_epoch,               47;
  Invalid_txn_state,                    48;
  Invalid_producer_id_mapping,          49;
  Invalid_transaction_timeout,          50;
  Concurrent_transactions,              51;
  Transaction_coordinator_fenced,       52;
  Transactional_id_authorization_failed, 53;
  Security_disabled,                    54;
  Operation_not_attempted,              55;
  Kafka_storage_error,                  56;
  Log_dir_not_found,                    57;
  Sasl_authentication_failed,           58;
  Unknown_producer_id,                  59;
  Reassignment_in_progress,             60;
  Unknown,                              -1;
  Begin,                              -200;
  Bad_msg,                            -199;
  Bad_compression,                    -198;
  Destroy,                            -197;
  Fail,                               -196;
  Transport,                          -195;
  Crit_sys_resource,                  -194;
  Resolve,                            -193;
  Msg_timed_out,                      -192;
  Partition_eof,                      -191;
  Unknown_partition,                  -190;
  Fs,                                 -189;
  Unknown_topic,                      -188;
  All_brokers_down,                   -187;
  Invalid_arg,                        -186;
  Timed_out,                          -185;
  Queue_full,                         -184;
  Isr_insuff,                         -183;
  Node_update,                        -182;
  Ssl,                                -181;
  Wait_coord,                         -180;
  Unknown_group,                      -179;
  In_progress,                        -178;
  Prev_in_progress,                   -177;
  Existing_subscription,              -176;
  Assign_partitions,                  -175;
  Revoke_partitions,                  -174;
  Conflict,                           -173;
  State,                              -172;
  Unknown_protocol,                   -171;
  Not_implemented,                    -170;
  Authentication,                     -169;
  No_offset,                          -168;
  Outdated,                           -167;
  Timed_out_queue,                    -166;
  Unsupported_feature,                -165;
  Wait_cache,                         -164;
  Intr,                               -163;
  Key_serialization,                  -162;
  Value_serialization,                -161;
  Key_deserialization,                -160;
  Value_deserialization,              -159;
  Partial,                            -158;
  Read_only,                          -157;
  Noent,                              -156;
  Underflow,                          -155;
  Invalid_type,                       -154;
  Retry,                              -153;
  Purge_queue,                        -152;
  Purge_inflight,                     -151;
  Fatal,                              -150;
  Inconsistent,                       -149;
  Gapless_guarantees,                 -148;
  Max_poll_exceeded,                  -147;
  Unknown_broker,                     -146;
  Not_configured,                     -145;
  Fenced,                             -144;
  Application,                        -143;
]

let of_int code =
  match List.find_opt (fun (_, c) -> c = code) table with
  | Some (v, _) -> v
  | None        -> Err_unknown code

(* to_string delegates to rd_kafka_err2str via FFI, which is the canonical
   source for human-readable error messages. We convert the variant back to
   its integer code using the same table. *)
let to_string t =
  let code = match t with
    | Err_unknown n -> n
    | _             ->
      (match List.find_opt (fun (v, _) -> v = t) table with
       | Some (_, c) -> c
       | None        -> -1)
  in
  Kafka_raw.err2str code

let is_retryable = function
  | Leader_not_available
  | Not_leader_for_partition
  | Coordinator_not_available
  | Coordinator_load_in_progress
  | Rebalance_in_progress
  | Request_timed_out
  | Network_exception
  | Transport
  | Timed_out
  | All_brokers_down
  | Resolve -> true
  | _ -> false

let is_fatal = function
  | Fatal
  | Destroy
  | Bad_msg
  | Bad_compression -> true
  | _ -> false
