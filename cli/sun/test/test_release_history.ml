(** Tests for CLOUD-003: release history list (pagination) and log retrieval. *)

let check_int  = Alcotest.(check int)
let check_bool = Alcotest.(check bool)

let memory_ops_of reg =
  { Sun_cli_control_plane.
    create_project        = Sun_cli_registry.create_project reg;
    get_project           = Sun_cli_registry.get_project reg;
    create_release        = Sun_cli_registry.create_release reg;
    list_releases         = Sun_cli_registry.list_releases reg;
    list_releases_page    = Sun_cli_registry.list_releases_page reg;
    get_release_logs      = (fun _project_id release_id ->
                               Sun_cli_registry.get_release_logs reg release_id);
    append_log_line       = Sun_cli_registry.append_log_line reg;
    update_service_digest = (fun rid svc img dig ->
                               Sun_cli_registry.update_service_digest reg rid
                                 ~service_name:svc ~image_ref:img ~digest_str:dig);
    update_release_status = (fun rid s -> Sun_cli_registry.update_release_status reg rid s);
  }

let make_registry_with_releases n =
  let r = Sun_cli_registry.create () in
  let p = Sun_cli_registry.create_project r ~workspace:"pluto"
    |> function Ok p -> p | Error m -> Alcotest.fail m in
  for i = 1 to n do
    ignore (Sun_cli_registry.create_release r
      ~project_id:p.Sun_cli_registry.project_id
      ~environment:"production"
      ~image_tag:(Printf.sprintf "tag-%d" i)
      ~service_names:["svc"]
      |> function Ok r -> r | Error m -> Alcotest.fail m)
  done;
  (r, p.Sun_cli_registry.project_id)

(* ── list_releases_page ─────────────────────────────────────────────────── *)

let test_list_page_basic () =
  let r, pid = make_registry_with_releases 5 in
  let items, total = Sun_cli_registry.list_releases_page r
      ~project_id:pid ~page:1 ~page_size:20 ()
    |> function Ok x -> x | Error m -> Alcotest.fail m in
  check_int "total" 5 total;
  check_int "items" 5 (List.length items)

let test_list_page_first_page () =
  let r, pid = make_registry_with_releases 5 in
  let items, total = Sun_cli_registry.list_releases_page r
      ~project_id:pid ~page:1 ~page_size:3 ()
    |> function Ok x -> x | Error m -> Alcotest.fail m in
  check_int "total" 5 total;
  check_int "page 1 count" 3 (List.length items)

let test_list_page_second_page () =
  let r, pid = make_registry_with_releases 5 in
  let items, total = Sun_cli_registry.list_releases_page r
      ~project_id:pid ~page:2 ~page_size:3 ()
    |> function Ok x -> x | Error m -> Alcotest.fail m in
  check_int "total" 5 total;
  check_int "page 2 count" 2 (List.length items)

let test_list_page_beyond_end () =
  let r, pid = make_registry_with_releases 3 in
  let items, total = Sun_cli_registry.list_releases_page r
      ~project_id:pid ~page:5 ~page_size:3 ()
    |> function Ok x -> x | Error m -> Alcotest.fail m in
  check_int "total" 3 total;
  check_int "beyond end" 0 (List.length items)

let test_list_page_empty () =
  let r = Sun_cli_registry.create () in
  ignore (Sun_cli_registry.create_project r ~workspace:"empty"
    |> function Ok p -> p | Error m -> Alcotest.fail m);
  let items, total = Sun_cli_registry.list_releases_page r
      ~project_id:"proj-empty" ~page:1 ~page_size:10 ()
    |> function Ok x -> x | Error m -> Alcotest.fail m in
  check_int "total" 0 total;
  check_int "items" 0 (List.length items)

let test_list_page_unknown_project () =
  let r = Sun_cli_registry.create () in
  let result = Sun_cli_registry.list_releases_page r
      ~project_id:"proj-ghost" ~page:1 ~page_size:10 () in
  check_bool "is error" true (Result.is_error result)

(* ── get_release_logs ───────────────────────────────────────────────────── *)

let test_logs_stub_lines_populated () =
  let r = Sun_cli_registry.create () in
  let p = Sun_cli_registry.create_project r ~workspace:"pluto"
    |> function Ok p -> p | Error m -> Alcotest.fail m in
  let rel = Sun_cli_registry.create_release r
      ~project_id:p.Sun_cli_registry.project_id
      ~environment:"production"
      ~image_tag:"abc123"
      ~service_names:["charge-svc"]
    |> function Ok r -> r | Error m -> Alcotest.fail m in
  let lines = Sun_cli_registry.get_release_logs r rel.Sun_cli_registry.release_id
    |> function Ok ls -> ls | Error m -> Alcotest.fail m in
  check_bool "non-empty log" true (List.length lines > 0)

let test_logs_contain_started_line () =
  let r = Sun_cli_registry.create () in
  let p = Sun_cli_registry.create_project r ~workspace:"pluto"
    |> function Ok p -> p | Error m -> Alcotest.fail m in
  let rel = Sun_cli_registry.create_release r
      ~project_id:p.Sun_cli_registry.project_id
      ~environment:"staging"
      ~image_tag:"abc123"
      ~service_names:[]
    |> function Ok r -> r | Error m -> Alcotest.fail m in
  let lines = Sun_cli_registry.get_release_logs r rel.Sun_cli_registry.release_id
    |> function Ok ls -> ls | Error m -> Alcotest.fail m in
  let has_started = List.exists (fun l ->
    let len = String.length l in
    let needle = "started" in
    let nlen = String.length needle in
    let rec go i = if i > len - nlen then false
      else if String.sub l i nlen = needle then true else go (i+1) in
    go 0) lines in
  check_bool "has started line" true has_started

let test_logs_contain_service_line () =
  let r = Sun_cli_registry.create () in
  let p = Sun_cli_registry.create_project r ~workspace:"pluto"
    |> function Ok p -> p | Error m -> Alcotest.fail m in
  let rel = Sun_cli_registry.create_release r
      ~project_id:p.Sun_cli_registry.project_id
      ~environment:"production"
      ~image_tag:"abc"
      ~service_names:["charge-svc"]
    |> function Ok r -> r | Error m -> Alcotest.fail m in
  let lines = Sun_cli_registry.get_release_logs r rel.Sun_cli_registry.release_id
    |> function Ok ls -> ls | Error m -> Alcotest.fail m in
  let has_svc = List.exists (fun l ->
    let needle = "charge-svc" in
    let nlen = String.length needle in
    let len = String.length l in
    let rec go i = if i > len - nlen then false
      else if String.sub l i nlen = needle then true else go (i+1) in
    go 0) lines in
  check_bool "charge-svc line present" true has_svc

let test_logs_unknown_release () =
  let r = Sun_cli_registry.create () in
  let result = Sun_cli_registry.get_release_logs r "rel-unknown" in
  check_bool "is error" true (Result.is_error result)

let test_logs_append () =
  let r = Sun_cli_registry.create () in
  let p = Sun_cli_registry.create_project r ~workspace:"pluto"
    |> function Ok p -> p | Error m -> Alcotest.fail m in
  let rel = Sun_cli_registry.create_release r
      ~project_id:p.Sun_cli_registry.project_id
      ~environment:"production" ~image_tag:"abc" ~service_names:[]
    |> function Ok r -> r | Error m -> Alcotest.fail m in
  let before = Sun_cli_registry.get_release_logs r rel.Sun_cli_registry.release_id
    |> function Ok ls -> List.length ls | Error m -> Alcotest.fail m in
  Sun_cli_registry.append_log_line r rel.Sun_cli_registry.release_id "custom line";
  let after = Sun_cli_registry.get_release_logs r rel.Sun_cli_registry.release_id
    |> function Ok ls -> List.length ls | Error m -> Alcotest.fail m in
  check_int "one more line" (before + 1) after

(* ── HTTP API ────────────────────────────────────────────────────────────── *)

let setup_with_releases n =
  let r = Sun_cli_registry.create () in
  let ops = memory_ops_of r in
  ignore (Sun_cli_control_plane.handle ops
    (Sun_cli_control_plane.post_projects ~workspace:"pluto"));
  for i = 1 to n do
    ignore (Sun_cli_control_plane.handle ops
      (Sun_cli_control_plane.post_release
        ~project_id:"proj-pluto"
        ~environment:"production"
        ~image_tag:(Printf.sprintf "tag-%d" i)
        ~service_names:["svc"]))
  done;
  (r, ops)

let test_get_releases_200 () =
  let _r, ops = setup_with_releases 3 in
  let resp = Sun_cli_control_plane.handle ops
    (Sun_cli_control_plane.get_releases ~project_id:"proj-pluto" ()) in
  check_int "status 200" 200 resp.Sun_cli_control_plane.status

let test_get_releases_returns_list () =
  let _r, ops = setup_with_releases 3 in
  let resp = Sun_cli_control_plane.handle ops
    (Sun_cli_control_plane.get_releases ~project_id:"proj-pluto" ()) in
  let open Yojson.Safe.Util in
  check_int "three releases" 3
    (resp.body |> member "releases" |> to_list |> List.length)

let test_get_releases_pagination () =
  let _r, ops = setup_with_releases 5 in
  let resp = Sun_cli_control_plane.handle ops
    (Sun_cli_control_plane.get_releases ~project_id:"proj-pluto"
       ~page:1 ~page_size:3 ()) in
  let open Yojson.Safe.Util in
  check_int "page 1 has 3" 3
    (resp.body |> member "releases" |> to_list |> List.length);
  check_int "total is 5" 5
    (resp.body |> member "total" |> to_int)

let test_get_releases_unknown_project () =
  let r = Sun_cli_registry.create () in
  let ops = memory_ops_of r in
  let resp = Sun_cli_control_plane.handle ops
    (Sun_cli_control_plane.get_releases ~project_id:"proj-ghost" ()) in
  check_int "404" 404 resp.Sun_cli_control_plane.status

let test_get_release_logs_200 () =
  let r, ops = setup_with_releases 1 in
  let releases = match Sun_cli_registry.list_releases r ~project_id:"proj-pluto" with
    | Ok rs -> rs | Error m -> Alcotest.fail m in
  let rid = (List.hd releases).Sun_cli_registry.release_id in
  let resp = Sun_cli_control_plane.handle ops
    (Sun_cli_control_plane.get_release_logs ~project_id:"proj-pluto" ~release_id:rid) in
  check_int "status 200" 200 resp.Sun_cli_control_plane.status

let test_get_release_logs_returns_lines () =
  let r, ops = setup_with_releases 1 in
  let releases = match Sun_cli_registry.list_releases r ~project_id:"proj-pluto" with
    | Ok rs -> rs | Error m -> Alcotest.fail m in
  let rid = (List.hd releases).Sun_cli_registry.release_id in
  let resp = Sun_cli_control_plane.handle ops
    (Sun_cli_control_plane.get_release_logs ~project_id:"proj-pluto" ~release_id:rid) in
  let open Yojson.Safe.Util in
  check_bool "non-empty lines" true
    (resp.body |> member "lines" |> to_list |> (<>) [])

let test_get_release_logs_unknown () =
  let r = Sun_cli_registry.create () in
  let ops = memory_ops_of r in
  let resp = Sun_cli_control_plane.handle ops
    (Sun_cli_control_plane.get_release_logs
       ~project_id:"proj-pluto" ~release_id:"rel-ghost") in
  check_int "404" 404 resp.Sun_cli_control_plane.status

let () =
  Alcotest.run "release_history"
    [ "list_releases_page", [
        Alcotest.test_case "basic"             `Quick test_list_page_basic;
        Alcotest.test_case "first page"        `Quick test_list_page_first_page;
        Alcotest.test_case "second page"       `Quick test_list_page_second_page;
        Alcotest.test_case "beyond end"        `Quick test_list_page_beyond_end;
        Alcotest.test_case "empty"             `Quick test_list_page_empty;
        Alcotest.test_case "unknown project"   `Quick test_list_page_unknown_project;
      ];
      "get_release_logs", [
        Alcotest.test_case "stub lines present"  `Quick test_logs_stub_lines_populated;
        Alcotest.test_case "started line"        `Quick test_logs_contain_started_line;
        Alcotest.test_case "service line"        `Quick test_logs_contain_service_line;
        Alcotest.test_case "unknown release"     `Quick test_logs_unknown_release;
        Alcotest.test_case "append"              `Quick test_logs_append;
      ];
      "HTTP GET /releases", [
        Alcotest.test_case "200 on success"      `Quick test_get_releases_200;
        Alcotest.test_case "returns list"        `Quick test_get_releases_returns_list;
        Alcotest.test_case "pagination"          `Quick test_get_releases_pagination;
        Alcotest.test_case "unknown project 404" `Quick test_get_releases_unknown_project;
      ];
      "HTTP GET /releases/{id}/logs", [
        Alcotest.test_case "200 on success"   `Quick test_get_release_logs_200;
        Alcotest.test_case "returns lines"    `Quick test_get_release_logs_returns_lines;
        Alcotest.test_case "unknown 404"      `Quick test_get_release_logs_unknown;
      ];
    ]
