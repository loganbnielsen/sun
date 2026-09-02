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

(* Which pod-count/lifecycle model a service follows -- kept local to this
   module rather than taking Sun_cli_manifest.primitive directly, so
   rollout diagnosis doesn't couple to manifest concepts; cmd_status.ml
   translates from primitive to this. *)
type pod_expectation =
  | Continuous
  (** Deployment/Rollout-backed (Svc, Worker): a pod should always be
      running; zero pods, or a pod that isn't [is_healthy], is a finding. *)
  | Ephemeral
  (** CronJob-backed (Fn): no pod at all between scheduled runs is the
      expected resting state. A *terminal* pod (phase "Succeeded" or
      "Failed") is history, not a live signal, and is never a finding
      either way -- `kubectl get pods -l app=<name>` can return several
      historical run pods at once (successfulJobsHistoryLimit/
      failedJobsHistoryLimit), and an old failed run must not keep the
      function looking DEGRADED after a later run succeeds. Only a
      currently *active* pod (Running/Pending) that isn't [is_healthy]
      -- e.g. crash-looping mid-run -- is a finding. *)

let is_terminal (p : pod_status) : bool =
  p.phase = "Succeeded" || p.phase = "Failed"

let is_ok_for ~pod_expectation (p : pod_status) : bool =
  match pod_expectation with
  | Continuous -> is_healthy p
  | Ephemeral -> is_healthy p || is_terminal p

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

(* An empty pod list is itself a finding, not silence, for [Continuous]
   (Svc/Worker): it means "never started" just as much as an unhealthy
   pod does (OBS-024) -- the whole point of this diagnosis, per its call
   sites, is to catch that case. It is NOT a finding for [Ephemeral]
   (Fn/CronJob) -- that has no pod at all except while a scheduled
   invocation is actively executing, and a terminal pod (succeeded or
   failed) is history, not a failure (OBS-024/026 follow-up: originally
   unconditional and falsely degraded every idle scheduled function, then
   every completed one, including ones that failed and were later
   superseded by a success).
   [~pod_expectation] is required, not defaulted -- the bug this fixes
   came from applying the wrong health model, so a caller must say which
   one it means rather than silently inheriting a default.
   Only meaningful when [pods] reflects a *confirmed* kubectl result;
   callers must not pass an empty list for "couldn't check" (see
   fetch_pod_statuses/diagnose_service_live below). *)
let format_service_diagnosis ~pod_expectation ~service_name
    (pods : pod_status list) (events : event list) : string option =
  if pods = [] then
    match pod_expectation with
    | Continuous ->
      Some (Printf.sprintf "%s rollout failed\n\nNo pods found for this service.\n" service_name)
    | Ephemeral -> None
  else
    let unhealthy = List.filter (fun p -> not (is_ok_for ~pod_expectation p)) pods in
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

let diagnose_service_live ~pod_expectation ~ns ~service_name ~k8s_name () : string option =
  match fetch_pod_statuses ~ns ~k8s_name with
  | None -> None
  | Some pods ->
    let events = fetch_namespace_events ~ns in
    format_service_diagnosis ~pod_expectation ~service_name pods events
