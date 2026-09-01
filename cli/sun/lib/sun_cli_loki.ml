(* Minimal Loki query client for 'sun logs'. Shells out to curl — same
   pattern this CLI already uses for kubectl/docker/helm/terraform — rather
   than pulling in an HTTP library for one blocking GET. *)

module U = Yojson.Safe.Util

let query_range_argv ~base_url ~ns ~k8s_name ~limit ~timeout_s : string list =
  let logql = Printf.sprintf {|{namespace="%s",app="%s"}|} ns k8s_name in
  [ "curl"; "-sS"; "--max-time"; string_of_float timeout_s;
    "-w"; "\n%{http_code}";
    "--get"; base_url ^ "/loki/api/v1/query_range";
    "--data-urlencode"; "query=" ^ logql;
    "--data-urlencode"; "limit=" ^ string_of_int limit;
    "--data-urlencode"; "direction=backward" ]

type line = { ts_ns : string; text : string }

(* curl's -w '\n%{http_code}' appends the status code as a final line after
   the response body; split it back off. *)
let split_body_and_status (raw : string) : string * int option =
  match String.rindex_opt raw '\n' with
  | None -> (raw, None)
  | Some i ->
    let body = String.sub raw 0 i in
    let code_str = String.sub raw (i + 1) (String.length raw - i - 1) in
    (body, int_of_string_opt (String.trim code_str))

let parse_query_range_body (body : string) : (line list, string) result =
  try
    let json = Yojson.Safe.from_string body in
    match U.member "status" json |> U.to_string_option with
    | Some "success" ->
      let streams = try U.member "data" json |> U.member "result" |> U.to_list with _ -> [] in
      let lines =
        List.concat_map (fun stream ->
          try
            U.member "values" stream |> U.to_list
            |> List.filter_map (fun v ->
                 match v with
                 | `List [ `String ts_ns; `String text ] -> Some { ts_ns; text }
                 | _ -> None)
          with _ -> []
        ) streams
      in
      Ok (List.sort (fun a b -> compare a.ts_ns b.ts_ns) lines)
    | Some other -> Error (Printf.sprintf "Loki returned status %S" other)
    | None -> Error "Loki response had no status field"
  with
  | Yojson.Json_error msg -> Error (Printf.sprintf "could not parse Loki response: %s" msg)
  | exn -> Error (Printf.sprintf "could not parse Loki response: %s" (Printexc.to_string exn))

type fetch_error =
  | Timeout
  | Connection_failed
  | Http_error of int
  | Other of string

let fetch_error_to_string = function
  | Timeout            -> "query timed out"
  | Connection_failed  -> "connection failed"
  | Http_error code    -> Printf.sprintf "HTTP %d" code
  | Other msg          -> msg

(* curl exit codes: 28 = operation timeout, 6/7/56 = couldn't resolve/connect/receive. *)
let classify_process_error (e : Sun_cli_process.error) : fetch_error =
  match e with
  | Sun_cli_process.Timeout _ -> Timeout
  | Sun_cli_process.Spawn_failed msg -> Other msg
  | Sun_cli_process.Non_zero { exit_code = 28; _ } -> Timeout
  | Sun_cli_process.Non_zero { exit_code = (6 | 7 | 56); _ } -> Connection_failed
  | Sun_cli_process.Non_zero { exit_code; stderr } ->
    Other (Printf.sprintf "curl exit %d: %s" exit_code stderr)

let query ~base_url ~ns ~k8s_name ?(limit = 100) ?(timeout_s = 5.0) ()
    : (line list, fetch_error) result =
  let argv = query_range_argv ~base_url ~ns ~k8s_name ~limit ~timeout_s in
  match Sun_cli_process.run (Sun_cli_process.cmd ~timeout_s:(timeout_s +. 2.0) argv) with
  | Error e -> Error (classify_process_error e)
  | Ok r when r.Sun_cli_process.exit_code <> 0 ->
    Error (Other (Printf.sprintf "curl exit %d: %s" r.Sun_cli_process.exit_code r.Sun_cli_process.stderr))
  | Ok r ->
    let (body, code) = split_body_and_status r.Sun_cli_process.stdout in
    (match code with
     | Some c when c < 200 || c >= 300 -> Error (Http_error c)
     | _ ->
       match parse_query_range_body body with
       | Ok lines -> Ok lines
       | Error msg -> Error (Other msg))
