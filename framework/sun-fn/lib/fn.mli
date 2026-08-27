type trigger =
  | Cron of string  (** Cron expression, e.g. ["0 * * * *"] for hourly. *)
  | Lambda
      (** Runs via the AWS Lambda Runtime API loop ([lambda-eio]) instead of
          once-and-exit — see [aws-audit.md] and [lambda-eio.md] for the
          full design. Not a general event-processing trigger: v1 does not
          thread the Lambda event payload into [F.run] at all, matching
          this module's existing "run once, report status" contract; a
          Lambda-triggered [-fn] is a cron job hosted on Lambda instead of a
          Kubernetes CronJob, not an S3/SQS/DynamoDB-Streams event handler. *)

module type FN = sig
  val trigger : trigger

  val run : unit -> (unit, string) result
  (** The function body. Called once per invocation; must return. *)
end

module Make (F : FN) : sig
  val run
    :  env:< net       : _ Eio.Net.t
           ; clock     : _ Eio.Time.clock
           ; mono_clock: _ Eio.Time.Mono.t
           ; .. >
    -> ?pushgateway_url:string
    (** Pushgateway base URL, e.g. "http://pushgateway:9091".
        If absent, metrics are recorded in-process but not pushed. *)
    -> ?job:string
    (** Pushgateway job label. Defaults to the cron schedule string for
        [Cron], or ["lambda"] for [Lambda]. *)
    -> ?backend:(Obs_eio.backend * (unit -> string))
    (** Override the default [Obs_prometheus.create ()] backend+renderer pair.
        Useful for composing with additional backends (e.g. [Obs_eio.compose]) or
        for inspecting rendered metrics in tests. *)
    -> unit
    -> unit
  (** [Cron _]: run [F.run ()] once, record metrics, push to Pushgateway if
      configured, then exit — unchanged from v1. On [Error msg] raises
      [Failure msg] (caller should [exit 1]). On SIGTERM/SIGINT exits with
      code 130.

      [Lambda]: loop forever via [Lambda_runtime.run_loop] ([lambda-eio]),
      calling [F.run ()] once per invocation and recording/pushing metrics
      per invocation — never exits on a successful invocation. A single
      invocation's [Error msg] is reported to the Runtime API via
      [Lambda_runtime.respond_error] and the loop continues; it does not
      raise [Failure] the way [Cron] does, since one bad invocation must
      not end the whole (reused-across-invocations) Lambda execution
      environment. On SIGTERM/SIGINT the loop stops after finishing
      whatever invocation is currently in flight (a Lambda execution
      environment being frozen/shut down sends SIGTERM — this is expected,
      routine shutdown, not the abnormal-exit signal [Cron]'s exit code 130
      represents), then this function returns normally instead of exiting
      the process — a Lambda runtime process should not call [exit] itself;
      the execution environment manages the process lifecycle. Requires
      [AWS_LAMBDA_RUNTIME_API] to be set (raises [Failure] immediately if
      not — this trigger only makes sense inside a real Lambda execution
      environment or a local Runtime Interface Emulator). *)
end
