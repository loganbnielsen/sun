(* Pure parsing/summarizing of kubectl pod + event JSON, used by 'sun status'
   to explain a failed rollout directly from Kubernetes state. This is the
   layer that works even when the app never started and Loki has nothing. *)

module J = Yojson.Safe.Util

type container_state =
  | Waiting     of { reason : string; message : string option }
  | Running
  | Terminated  of { reason : string; exit_code : int; message : string option }
  | Unknown_state

type pod_status = {
  name                    : string;
  phase                   : string;
  ready                   : bool;
  restarts                : int;
  image                   : string option;
  state                   : container_state;
  last_terminated_reason  : string option;
}

type event = {
  ev_type        : string;
  reason         : string;
  message        : string;
  count          : int;
  last_timestamp : string option;
  involved_name  : string;
}

let member_opt key j = try Some (J.member key j) with _ -> None
let is_null = function None | Some `Null -> true | Some _ -> false

let to_string_opt = function `String s -> Some s | _ -> None
let to_int_opt = function `Int i -> Some i | _ -> None
let to_bool_opt = function `Bool b -> Some b | _ -> None

let parse_container_state (c : Yojson.Safe.t) : container_state =
  match member_opt "state" c with
  | None -> Unknown_state
  | Some state ->
    let waiting = member_opt "waiting" state in
    let running = member_opt "running" state in
    let terminated = member_opt "terminated" state in
    if not (is_null waiting) then
      let w = Option.get waiting in
      let reason = J.member "reason" w |> to_string_opt |> Option.value ~default:"Unknown" in
      let message = J.member "message" w |> to_string_opt in
      Waiting { reason; message }
    else if not (is_null running) then
      Running
    else if not (is_null terminated) then
      let t = Option.get terminated in
      let reason = J.member "reason" t |> to_string_opt |> Option.value ~default:"Unknown" in
      let exit_code = J.member "exitCode" t |> to_int_opt |> Option.value ~default:0 in
      let message = J.member "message" t |> to_string_opt in
      Terminated { reason; exit_code; message }
    else
      Unknown_state

let parse_last_terminated_reason (c : Yojson.Safe.t) : string option =
  match member_opt "lastState" c with
  | None -> None
  | Some ls ->
    (match member_opt "terminated" ls with
     | Some t when not (is_null (Some t)) -> J.member "reason" t |> to_string_opt
     | _ -> None)

let parse_pod (item : Yojson.Safe.t) : pod_status =
  let name =
    J.member "metadata" item |> J.member "name" |> to_string_opt
    |> Option.value ~default:"unknown"
  in
  let status = J.member "status" item in
  let phase = J.member "phase" status |> to_string_opt |> Option.value ~default:"Unknown" in
  let container_statuses =
    match member_opt "containerStatuses" status with
    | Some (`List l) -> l
    | _ -> []
  in
  match container_statuses with
  | [] ->
    { name; phase; ready = false; restarts = 0; image = None;
      state = Unknown_state; last_terminated_reason = None }
  | c :: _ ->
    let ready = J.member "ready" c |> to_bool_opt |> Option.value ~default:false in
    let restarts = J.member "restartCount" c |> to_int_opt |> Option.value ~default:0 in
    let image = J.member "image" c |> to_string_opt in
    let state = parse_container_state c in
    let last_terminated_reason = parse_last_terminated_reason c in
    { name; phase; ready; restarts; image; state; last_terminated_reason }

let parse_pods_json (s : string) : pod_status list =
  try
    match member_opt "items" (Yojson.Safe.from_string s) with
    | Some (`List items) -> List.map parse_pod items
    | _ -> []
  with _ -> []

let parse_event (item : Yojson.Safe.t) : event option =
  try
    let involved_name =
      J.member "involvedObject" item |> J.member "name" |> to_string_opt
      |> Option.value ~default:""
    in
    let ev_type = J.member "type" item |> to_string_opt |> Option.value ~default:"Normal" in
    let reason = J.member "reason" item |> to_string_opt |> Option.value ~default:"" in
    let message = J.member "message" item |> to_string_opt |> Option.value ~default:"" in
    let count = J.member "count" item |> to_int_opt |> Option.value ~default:1 in
    let last_timestamp = J.member "lastTimestamp" item |> to_string_opt in
    Some { ev_type; reason; message; count; last_timestamp; involved_name }
  with _ -> None

let parse_events_json (s : string) : event list =
  try
    match member_opt "items" (Yojson.Safe.from_string s) with
    | Some (`List items) -> List.filter_map parse_event items
    | _ -> []
  with _ -> []

let events_for_pod ?(limit = 5) ~pod_name (events : event list) : event list =
  events
  |> List.filter (fun e -> e.involved_name = pod_name)
  |> List.sort (fun a b -> compare a.last_timestamp b.last_timestamp)
  |> List.rev
  |> List.filteri (fun i _ -> i < limit)

let is_healthy (p : pod_status) : bool =
  p.phase = "Running" && p.ready && (p.state = Running)

(* See the .mli for what Continuous/Ephemeral mean and why. *)
type pod_expectation = Continuous | Ephemeral

let format_pod_diagnosis (p : pod_status) (events : event list) : string =
  let buf = Buffer.create 256 in
  let headline = match p.state with
    | Waiting { reason; _ } -> reason
    | Terminated { reason; _ } -> reason
    | Running | Unknown_state -> p.phase
  in
  Buffer.add_string buf (Printf.sprintf "Pod %s: %s\n" p.name headline);
  (match p.state with
   | Waiting { reason; message } ->
     Buffer.add_string buf
       (Printf.sprintf "Reason: %s%s\n" reason
          (match message with Some m -> " — " ^ m | None -> ""))
   | Terminated { reason; exit_code; message } ->
     Buffer.add_string buf
       (Printf.sprintf "Reason: %s (exit code %d)%s\n" reason exit_code
          (match message with Some m -> " — " ^ m | None -> ""))
   | Running | Unknown_state -> ());
  (match p.last_terminated_reason with
   | Some r when p.restarts > 0 -> Buffer.add_string buf (Printf.sprintf "Last termination: %s\n" r)
   | _ -> ());
  if p.restarts > 0 then Buffer.add_string buf (Printf.sprintf "Restarts: %d\n" p.restarts);
  (match p.image with
   | Some img -> Buffer.add_string buf (Printf.sprintf "Image: %s\n" img)
   | None -> ());
  if events <> [] then begin
    Buffer.add_string buf "Last events:\n";
    List.iter (fun e -> Buffer.add_string buf (Printf.sprintf "  %s: %s\n" e.reason e.message)) events
  end;
  Buffer.contents buf

(* An empty pod list is itself a finding, not silence -- "never started"
   is as much a failure as an unhealthy pod. [Continuous] only (see
   [format_cronjob_diagnosis] for [Ephemeral]); [pods] must be a
   *confirmed* kubectl result, never an empty list standing in for
   "couldn't check". *)
let format_service_diagnosis ~service_name
    (pods : pod_status list) (events : event list) : string option =
  if pods = [] then
    Some (Printf.sprintf "%s rollout failed\n\nNo pods found for this service.\n" service_name)
  else
    let unhealthy = List.filter (fun p -> not (is_healthy p)) pods in
    if unhealthy = [] then None
    else begin
      let buf = Buffer.create 512 in
      Buffer.add_string buf (Printf.sprintf "%s rollout failed\n\n" service_name);
      List.iter (fun p ->
        Buffer.add_string buf (format_pod_diagnosis p (events_for_pod ~pod_name:p.name events));
        Buffer.add_char buf '\n'
      ) unhealthy;
      Some (Buffer.contents buf)
    end

(* CronJob status, as Kubernetes itself tracks it -- the authoritative
   source for "did the most recently scheduled run succeed," which pod
   inspection can't answer reliably once more than one historical pod is
   retained (OBS-026). *)
type cronjob_status = {
  last_schedule_time   : string option;
  last_successful_time : string option;
  active_count         : int;
}

let parse_cronjob_status (s : string) : cronjob_status option =
  try
    let j = Yojson.Safe.from_string s in
    match J.member "status" j with
    | `Null -> Some { last_schedule_time = None; last_successful_time = None; active_count = 0 }
    | status ->
      let last_schedule_time = J.member "lastScheduleTime" status |> to_string_opt in
      let last_successful_time = J.member "lastSuccessfulTime" status |> to_string_opt in
      let active_count =
        match member_opt "active" status with
        | Some (`List l) -> List.length l
        | _ -> 0
      in
      Some { last_schedule_time; last_successful_time; active_count }
  with _ -> None

(* Distinguishes "confirmed absent" from "the kubectl call failed": a Fn
   whose CronJob was never created must not read as healthy just because
   nothing could be fetched. *)
type cronjob_fetch_result =
  | Found of cronjob_status
  | Missing
  (** Confirmed via kubectl's own NotFound response -- not a transient
      failure. *)
  | Unavailable
  (** The kubectl call itself failed, or its output couldn't be parsed
      (transient error, timeout, RBAC, ...) -- stays silent, same as
      other transient-failure handling in this module. *)

(* Timestamps compare via parsed Ptime values, not raw strings: RFC3339
   timestamps aren't always the same width (fractional seconds vary), so
   string comparison can sort them wrong. A timestamp that fails to parse
   fails toward surfacing a finding, not hiding one. *)
let is_at_or_after ~reference candidate =
  match Ptime.of_rfc3339 candidate, Ptime.of_rfc3339 reference with
  | Ok (t_candidate, _, _), Ok (t_reference, _, _) -> Ptime.compare t_candidate t_reference >= 0
  | _ -> false

(* [Ephemeral] diagnosis covers only the CronJob's last *completed* run:
   an active run (active_count > 0) is never flagged here even if its pod
   is stuck -- bounded by backoffLimit, not indefinite; diagnosing an
   active run's own pod health is separate work. Idle between runs, the
   most recently scheduled run needs a later-or-equal recorded success,
   or it's a finding. [Missing] is always a finding. *)
let format_cronjob_diagnosis ~service_name (result : cronjob_fetch_result) : string option =
  match result with
  | Unavailable -> None
  | Missing ->
    Some (Printf.sprintf "%s rollout failed\n\nCronJob not found for this service.\n" service_name)
  | Found status ->
    if status.active_count > 0 then None
    else
      match status.last_schedule_time with
      | None -> None
      | Some scheduled ->
        let succeeded_since = match status.last_successful_time with
          | Some succeeded -> is_at_or_after ~reference:scheduled succeeded
          | None -> false
        in
        if succeeded_since then None
        else
          Some (Printf.sprintf
                  "%s rollout failed\n\nMost recently scheduled run (%s) did not complete successfully.\n"
                  service_name scheduled)

let fetch_namespace_events ~ns : event list =
  match Sun_cli_kubectl.get_raw ~args:["get"; "events"; "-n"; ns; "-o"; "json"] with
  | Ok r when r.Sun_cli_process.exit_code = 0 -> parse_events_json r.Sun_cli_process.stdout
  | _ -> []

(* [None] means the kubectl call itself failed (transient error, timeout,
   ...) -- distinct from [Some []], a confirmed zero pods. Conflating the
   two used to mean a transient failure and "no pods deployed" looked
   identical to callers; format_service_diagnosis now treats a confirmed
   empty list as a real finding, so this distinction matters. *)
let fetch_pod_statuses ~ns ~k8s_name : pod_status list option =
  match Sun_cli_kubectl.get_raw
          ~args:["get"; "pods"; "-n"; ns; "-l"; "app=" ^ k8s_name; "-o"; "json"] with
  | Ok r when r.Sun_cli_process.exit_code = 0 -> Some (parse_pods_json r.Sun_cli_process.stdout)
  | _ -> None

let fetch_cronjob_status ~ns ~k8s_name : cronjob_fetch_result =
  match Sun_cli_kubectl.get_raw ~args:["get"; "cronjob"; k8s_name; "-n"; ns; "-o"; "json"] with
  | Error _ -> Unavailable
  | Ok r when r.Sun_cli_process.exit_code = 0 ->
    (match parse_cronjob_status r.Sun_cli_process.stdout with
     | Some status -> Found status
     | None -> Unavailable)
  | Ok r ->
    if Sun_cli_port_forward.string_contains ~needle:"NotFound" r.Sun_cli_process.stderr
    then Missing else Unavailable

let diagnose_service_live ~pod_expectation ~ns ~service_name ~k8s_name () : string option =
  match pod_expectation with
  | Continuous ->
    (match fetch_pod_statuses ~ns ~k8s_name with
     | None -> None
     | Some pods ->
       let events = fetch_namespace_events ~ns in
       format_service_diagnosis ~service_name pods events)
  | Ephemeral ->
    format_cronjob_diagnosis ~service_name (fetch_cronjob_status ~ns ~k8s_name)
