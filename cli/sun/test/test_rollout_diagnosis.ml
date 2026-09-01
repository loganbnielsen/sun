let check_string = Alcotest.(check string)
let check_bool   = Alcotest.(check bool)
let check_int    = Alcotest.(check int)

module D = Sun_cli_rollout_diagnosis

let healthy_pod_json = {|
{"items": [
  {"metadata": {"name": "charge-svc-abc"},
   "status": {"phase": "Running",
     "containerStatuses": [
       {"ready": true, "restartCount": 0, "image": "registry/charge-svc:sha1",
        "state": {"running": {"startedAt": "2026-09-01T00:00:00Z"}}}
     ]}}
]}
|}

let image_pull_backoff_json = {|
{"items": [
  {"metadata": {"name": "charge-svc-xyz"},
   "status": {"phase": "Pending",
     "containerStatuses": [
       {"ready": false, "restartCount": 0, "image": "registry/charge-svc:bad-tag",
        "state": {"waiting": {"reason": "ImagePullBackOff",
                               "message": "Back-off pulling image \"registry/charge-svc:bad-tag\""}}}
     ]}}
]}
|}

let crash_loop_json = {|
{"items": [
  {"metadata": {"name": "charge-svc-crash"},
   "status": {"phase": "Running",
     "containerStatuses": [
       {"ready": false, "restartCount": 6, "image": "registry/charge-svc:sha2",
        "state": {"waiting": {"reason": "CrashLoopBackOff", "message": null}},
        "lastState": {"terminated": {"reason": "OOMKilled", "exitCode": 137}}}
     ]}}
]}
|}

let pending_no_containers_json = {|
{"items": [
  {"metadata": {"name": "charge-svc-pending"},
   "status": {"phase": "Pending"}}
]}
|}

let events_json = {|
{"items": [
  {"type": "Warning", "reason": "FailedPull", "message": "rpc error: pull access denied",
   "count": 3, "lastTimestamp": "2026-09-01T00:00:01Z",
   "involvedObject": {"kind": "Pod", "name": "charge-svc-xyz"}},
  {"type": "Warning", "reason": "BackOff", "message": "Back-off pulling image",
   "count": 5, "lastTimestamp": "2026-09-01T00:00:05Z",
   "involvedObject": {"kind": "Pod", "name": "charge-svc-xyz"}},
  {"type": "Warning", "reason": "FailedScheduling", "message": "0/2 nodes available",
   "count": 1, "lastTimestamp": "2026-09-01T00:00:00Z",
   "involvedObject": {"kind": "Pod", "name": "charge-svc-pending"}},
  {"type": "Normal", "reason": "Scheduled", "message": "unrelated pod",
   "count": 1, "lastTimestamp": "2026-09-01T00:00:00Z",
   "involvedObject": {"kind": "Pod", "name": "other-svc-abc"}}
]}
|}

(* ── parse_pods_json ─────────────────────────────────────────────────── *)

let test_parse_healthy_pod () =
  match D.parse_pods_json healthy_pod_json with
  | [ p ] ->
    check_string "name" "charge-svc-abc" p.name;
    check_string "phase" "Running" p.phase;
    check_bool "ready" true p.ready;
    check_int "restarts" 0 p.restarts;
    check_bool "is_healthy" true (D.is_healthy p)
  | _ -> Alcotest.fail "expected exactly one pod"

let test_parse_image_pull_backoff () =
  match D.parse_pods_json image_pull_backoff_json with
  | [ p ] ->
    check_bool "is_healthy" false (D.is_healthy p);
    (match p.state with
     | D.Waiting { reason; _ } -> check_string "reason" "ImagePullBackOff" reason
     | _ -> Alcotest.fail "expected Waiting state")
  | _ -> Alcotest.fail "expected exactly one pod"

let test_parse_crash_loop_last_termination () =
  match D.parse_pods_json crash_loop_json with
  | [ p ] ->
    check_int "restarts" 6 p.restarts;
    check_string "last_terminated_reason" "OOMKilled"
      (Option.value ~default:"none" p.last_terminated_reason)
  | _ -> Alcotest.fail "expected exactly one pod"

let test_parse_pod_with_no_container_statuses () =
  match D.parse_pods_json pending_no_containers_json with
  | [ p ] ->
    check_string "phase" "Pending" p.phase;
    check_bool "is_healthy" false (D.is_healthy p)
  | _ -> Alcotest.fail "expected exactly one pod"

(* ── parse_events_json / events_for_pod ─────────────────────────────── *)

let test_events_for_pod_filters_and_orders () =
  let events = D.parse_events_json events_json in
  let for_xyz = D.events_for_pod ~pod_name:"charge-svc-xyz" events in
  check_int "two events for charge-svc-xyz" 2 (List.length for_xyz);
  check_string "most recent first" "BackOff" (List.hd for_xyz).D.reason

let test_events_for_pod_excludes_other_pods () =
  let events = D.parse_events_json events_json in
  let for_other = D.events_for_pod ~pod_name:"charge-svc-abc" events in
  check_int "no events for unrelated pod" 0 (List.length for_other)

(* ── format_service_diagnosis ───────────────────────────────────────── *)

let test_format_service_diagnosis_none_when_healthy () =
  let pods = D.parse_pods_json healthy_pod_json in
  check_bool "no diagnosis for healthy service" true
    (Option.is_none (D.format_service_diagnosis ~service_name:"charge-svc" pods []))

let test_format_service_diagnosis_includes_events_and_reason () =
  let pods = D.parse_pods_json image_pull_backoff_json in
  let events = D.parse_events_json events_json in
  match D.format_service_diagnosis ~service_name:"charge-svc" pods events with
  | None -> Alcotest.fail "expected a diagnosis"
  | Some diagnosis ->
    check_bool "mentions rollout failed" true
      (try ignore (Str.search_forward (Str.regexp_string "charge-svc rollout failed") diagnosis 0); true
       with Not_found -> false);
    check_bool "mentions ImagePullBackOff" true
      (try ignore (Str.search_forward (Str.regexp_string "ImagePullBackOff") diagnosis 0); true
       with Not_found -> false);
    check_bool "mentions FailedPull event" true
      (try ignore (Str.search_forward (Str.regexp_string "FailedPull") diagnosis 0); true
       with Not_found -> false)

let () =
  Alcotest.run "rollout_diagnosis"
    [ ("parse_pods_json",
       [ Alcotest.test_case "healthy pod" `Quick test_parse_healthy_pod;
         Alcotest.test_case "image pull backoff" `Quick test_parse_image_pull_backoff;
         Alcotest.test_case "crash loop last termination" `Quick test_parse_crash_loop_last_termination;
         Alcotest.test_case "pod with no container statuses" `Quick test_parse_pod_with_no_container_statuses;
       ]);
      ("events",
       [ Alcotest.test_case "filters and orders by pod" `Quick test_events_for_pod_filters_and_orders;
         Alcotest.test_case "excludes other pods" `Quick test_events_for_pod_excludes_other_pods;
       ]);
      ("format_service_diagnosis",
       [ Alcotest.test_case "none when healthy" `Quick test_format_service_diagnosis_none_when_healthy;
         Alcotest.test_case "includes events and reason" `Quick test_format_service_diagnosis_includes_events_and_reason;
       ]);
    ]
