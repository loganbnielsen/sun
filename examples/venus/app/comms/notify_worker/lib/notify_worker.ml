(** comms / notify-worker — Worker.WORKER implementation.
    Consumes Charged events, logs them via Obs, and records a notification
    in PostgreSQL. The pool and observability handle are injected via functor
    so the module itself has no mutable state. *)

module Make (Config : sig
  val pool : Db.pool option
  val ot   : Obs.t
end) = struct
  module Message = Charged

  let group_id = "comms-notify-worker"

  let handle (msg : Message.t) ~ack ~trace_ctx =
    ack ();
    Obs.with_span Config.ot ?parent:trace_ctx "record_notification" (fun span ->
      Obs.log span Info
        ~fields:[("charge_id",    msg.Message.charge_id);
                 ("customer_id",  msg.Message.customer_id);
                 ("amount_cents", string_of_int msg.Message.amount_cents);
                 ("currency",     msg.Message.currency)]
        "recording charge notification"
    );
    (match Config.pool with
     | None -> ()
     | Some pool ->
       let row = Notification.Schema.{
         charge_id    = msg.Message.charge_id;
         amount_cents = msg.Message.amount_cents;
         customer_id  = msg.Message.customer_id;
         currency     = msg.Message.currency;
       } in
       (match Notification.insert pool row with
        | Ok ()   -> ()
        | Error e ->
          Printf.eprintf "[notify-worker] db error: %s\n%!" (Storage_error.to_string e)));
    Printf.printf "[notify-worker] recorded   charge=%-20s  customer=%-10s  %5d %s\n%!"
      msg.Message.charge_id msg.Message.customer_id
      msg.Message.amount_cents msg.Message.currency;
    Ok ()
end
