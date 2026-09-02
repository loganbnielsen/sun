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

let succeeded_pod_json = {|
{"items": [
  {"metadata": {"name": "invoice-fn-abc"},
   "status": {"phase": "Succeeded",
     "containerStatuses": [
       {"ready": false, "restartCount": 0, "image": "registry/invoice-fn:sha1",
        "state": {"terminated": {"reason": "Completed", "exitCode": 0}}}
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

(* OBS-024: an empty pod list is itself a finding ("never started"), not
   silence -- a declared service with a missing/scaled-to-zero/broken
   Deployment used to vacuously look healthy since "no unhealthy pods"
   trivially held for an empty list too. *)
let test_format_service_diagnosis_reports_empty_pod_list () =
  match D.format_service_diagnosis ~service_name:"charge-svc" [] [] with
  | None -> Alcotest.fail "expected a diagnosis for zero pods, got None (looks healthy)"
  | Some diagnosis ->
    check_bool "mentions rollout failed" true
      (try ignore (Str.search_forward (Str.regexp_string "charge-svc rollout failed") diagnosis 0); true
       with Not_found -> false);
    check_bool "mentions no pods found" true
      (try ignore (Str.search_forward (Str.regexp_string "No pods found") diagnosis 0); true
       with Not_found -> false)

(* OBS-024 follow-up: an Fn (CronJob-backed) has no pod between scheduled
   runs by design -- ~pod_expectation:Ephemeral must keep an empty pod
   list looking healthy, unlike a Svc/Worker (Continuous). *)
let test_format_service_diagnosis_empty_pods_ok_when_ephemeral () =
  check_bool "no diagnosis for an idle Fn with zero pods" true
    (Option.is_none
       (D.format_service_diagnosis ~pod_expectation:D.Ephemeral
          ~service_name:"invoice-fn" [] []))

let test_format_service_diagnosis_default_still_flags_empty_pods () =
  check_bool "default (Continuous) still flags empty pods" true
    (Option.is_some (D.format_service_diagnosis ~service_name:"charge-svc" [] []))

(* Even an Ephemeral primitive should still be flagged while a pod is
   actually present and unhealthy (e.g. a scheduled run stuck
   crash-looping) -- Ephemeral only changes the empty-list/completed-pod
   cases. *)
let test_format_service_diagnosis_unhealthy_pods_still_flagged_when_ephemeral () =
  let pods = D.parse_pods_json image_pull_backoff_json in
  check_bool "unhealthy pod still flagged for an Ephemeral primitive" true
    (Option.is_some
       (D.format_service_diagnosis ~pod_expectation:D.Ephemeral
          ~service_name:"invoice-fn" pods []))

(* OBS-026 (fifth-round review of PR #85): a CronJob pod that ran to
   completion successfully (phase "Succeeded") is not a failure for
   Ephemeral -- the fix for idle (zero-pod) Fn services didn't cover the
   equally-common case of a *completed* one. *)
let test_format_service_diagnosis_succeeded_pod_ok_when_ephemeral () =
  let pods = D.parse_pods_json succeeded_pod_json in
  check_bool "successfully completed pod is not a diagnosis for Ephemeral" true
    (Option.is_none
       (D.format_service_diagnosis ~pod_expectation:D.Ephemeral
          ~service_name:"invoice-fn" pods []))

let test_format_service_diagnosis_succeeded_pod_still_flagged_when_continuous () =
  let pods = D.parse_pods_json succeeded_pod_json in
  check_bool "a Succeeded pod is still a finding for Continuous (Svc/Worker)" true
    (Option.is_some
       (D.format_service_diagnosis ~service_name:"charge-svc" pods []))

let test_is_successfully_completed () =
  let succeeded = D.parse_pods_json succeeded_pod_json in
  let running = D.parse_pods_json healthy_pod_json in
  check_bool "Succeeded phase -> true" true
    (List.for_all D.is_successfully_completed succeeded);
  check_bool "Running phase -> false" false
    (List.exists D.is_successfully_completed running)

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
         Alcotest.test_case "reports empty pod list, not healthy" `Quick test_format_service_diagnosis_reports_empty_pod_list;
         Alcotest.test_case "empty pods OK when Ephemeral (Fn)" `Quick test_format_service_diagnosis_empty_pods_ok_when_ephemeral;
         Alcotest.test_case "default still flags empty pods" `Quick test_format_service_diagnosis_default_still_flags_empty_pods;
         Alcotest.test_case "unhealthy pods still flagged when Ephemeral" `Quick test_format_service_diagnosis_unhealthy_pods_still_flagged_when_ephemeral;
         Alcotest.test_case "succeeded pod OK when Ephemeral" `Quick test_format_service_diagnosis_succeeded_pod_ok_when_ephemeral;
         Alcotest.test_case "succeeded pod still flagged when Continuous" `Quick test_format_service_diagnosis_succeeded_pod_still_flagged_when_continuous;
         Alcotest.test_case "is_successfully_completed" `Quick test_is_successfully_completed;
       ]);
    ]
