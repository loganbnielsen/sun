(* Parser for sun.toml — backed by otoml (TOML 1.0.0 compliant).
   Reads the infra block:
     [infra.scale]    replicas, cpu, memory
     [infra.env]      config = { KEY = "val", ... }   (inline table)
                      secrets = ["KEY", ...]
     [infra.deploy]   rollout_strategy, ingress_host, ingress_path
     [infra.labels]   extra_labels = { key = "val", ... }  (inline table)
     [infra.rollout]  strategy, steps (progressive delivery via Argo Rollouts)
   Unknown keys and sections are silently forwarded-compatible.
   Malformed TOML now raises a clear Parse_error rather than silently returning
   partial data. *)

type rollout_strategy = Recreate | RollingUpdate

type canary_step =
  | Weight of int
  | Pause  of int option

type progressive_delivery =
  | Canary     of { steps : canary_step list }
  | Blue_green

type t = {
  replicas             : int option;
  cpu                  : string option;
  memory               : string option;
  env_config           : (string * string) list;
  secret_keys          : string list;
  rollout_strategy     : rollout_strategy option;
  ingress_host         : string option;
  ingress_path         : string option;
  extra_labels         : (string * string) list;
  progressive_delivery : progressive_delivery option;
}

let empty = {
  replicas             = None;
  cpu                  = None;
  memory               = None;
  env_config           = [];
  secret_keys          = [];
  rollout_strategy     = None;
  ingress_host         = None;
  ingress_path         = None;
  extra_labels         = [];
  progressive_delivery = None;
}

type parse_error =
  | Toml_syntax of { path : string; message : string }
  | Validation  of { path : string; message : string }

let parse_error_to_string = function
  | Toml_syntax { path; message }
  | Validation { path; message } ->
    Printf.sprintf "%s: %s" path message

let validation_error path message = Error (Validation { path; message })

let ( let* ) = Result.bind

(* ── Validation ──────────────────────────────────────────────────────────── *)

let parse_rollout_strategy path s =
  match s with
  | "Recreate"      -> Ok Recreate
  | "RollingUpdate" -> Ok RollingUpdate
  | other ->
    validation_error path (Printf.sprintf
      "sun.toml: unsupported rollout_strategy %S — \
       valid values are \"Recreate\" and \"RollingUpdate\"" other)

(* Guard: keys starting with "sun.dev/" are reserved for Sun internals. *)
let validate_extra_label_key k =
  let prefix = "sun.dev/" in
  if String.starts_with ~prefix k then
    Error (Printf.sprintf
      "sun.toml: extra_labels key %S is reserved — \
       keys may not start with \"sun.dev/\"" k)
  else
    Ok ()

let validate_weight n =
  if n < 0 || n > 100 then
    Error (Printf.sprintf
      "sun.toml: [infra.rollout] canary weight %d is invalid — \
       weights must be between 0 and 100" n)
  else
    Ok ()

let validate_duration d =
  if d <= 0 then
    Error (Printf.sprintf
      "sun.toml: [infra.rollout] pause duration %d is invalid — \
       durations must be positive seconds" d)
  else
    Ok ()

let validate_canary_step = function
  | Weight n ->
    validate_weight n
  | Pause None ->
    Ok ()
  | Pause (Some d) ->
    validate_duration d

(* ── Canary step parsing ─────────────────────────────────────────────────── *)

(* Parse a single step TOML value (an inline table).
   Accepts: {weight = 10}, {pause = {}}, {pause = {duration = 60}}.
   The weight-only shorthand [10, 40, 100] is handled at the array level below. *)
let parse_canary_step_value path v =
  (* An inline table with either a "weight" or "pause" key *)
  let* pairs =
    try Otoml.get_table v
        |> Result.ok
    with Otoml.Type_error _ ->
      validation_error path
        "sun.toml: [infra.rollout] canary step must be an inline table \
         like {weight = 10} or {pause = {}}"
  in
  match List.assoc_opt "weight" pairs with
  | Some wv ->
    let* n =
      try Otoml.get_integer wv
          |> Result.ok
      with Otoml.Type_error _ ->
        validation_error path
          "sun.toml: [infra.rollout] canary weight must be an integer"
    in
    let step = Weight n in
    let* () =
      validate_canary_step step
      |> Result.map_error (fun message -> Validation { path; message })
    in
    Ok step
  | None ->
    (match List.assoc_opt "pause" pairs with
     | Some pv ->
       let* inner =
         try Otoml.get_table pv
             |> Result.ok
         with Otoml.Type_error _ ->
           validation_error path
             "sun.toml: [infra.rollout] pause value must be an inline table \
              like {} or {duration = 60}"
       in
       let* step =
         match List.assoc_opt "duration" inner with
         | Some dv ->
           let* d =
             try Otoml.get_integer dv
                 |> Result.ok
             with Otoml.Type_error _ ->
               validation_error path
                 "sun.toml: [infra.rollout] pause duration must be an integer"
           in
           Ok (Pause (Some d))
         | None ->
           Ok (Pause None)
       in
       let* () =
         validate_canary_step step
         |> Result.map_error (fun message -> Validation { path; message })
       in
       Ok step
     | None ->
       validation_error path
         "sun.toml: unsupported [infra.rollout] canary step — \
          expected {weight = N} or {pause = {...}}")

(* Parse the steps array. Supports:
   - Integer shorthand: steps = [10, 40, 100]  (each int → Weight n)
   - Table steps: steps = [{weight = 10}, {pause = {}}, ...]
   Mixed arrays (some ints, some tables) are rejected by the TOML parser. *)
let parse_steps path doc =
  match Otoml.find_opt doc Otoml.get_value ["infra"; "rollout"; "steps"] with
  | None -> Ok []
  | Some arr_v ->
    let* items =
      try Otoml.get_array Otoml.get_value arr_v
          |> Result.ok
      with Otoml.Type_error _ ->
        validation_error path "sun.toml: [infra.rollout] steps must be an array"
    in
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
      match item with
      | Otoml.TomlInteger n ->
        let step = Weight n in
        let* () =
          validate_canary_step step
          |> Result.map_error (fun message -> Validation { path; message })
        in
        loop (step :: acc) rest
      | _ ->
        let* step = parse_canary_step_value path item in
        loop (step :: acc) rest
    in
    loop [] items

(* ── Loader ──────────────────────────────────────────────────────────────── *)

let load_result path =
  if not (Sys.file_exists path) then Ok empty
  else begin
    let* doc =
      match Otoml.Parser.from_file_result path with
      | Ok d -> Ok d
      | Error msg ->
        Error (Toml_syntax { path; message = Printf.sprintf "sun.toml: %s" msg })
    in

    (* [infra.scale] *)
    let replicas =
      Otoml.Helpers.find_integer_opt doc ["infra"; "scale"; "replicas"]
    in
    let cpu =
      Otoml.Helpers.find_string_opt doc ["infra"; "scale"; "cpu"]
    in
    let memory =
      Otoml.Helpers.find_string_opt doc ["infra"; "scale"; "memory"]
    in

    (* [infra.env] *)
    let* env_config =
      match Otoml.find_opt doc Otoml.get_value ["infra"; "env"; "config"] with
      | None -> Ok []
      | Some v ->
        (try
           Otoml.get_table_values Otoml.get_string v
           |> Result.ok
         with Otoml.Type_error _ ->
           validation_error path
             "sun.toml: [infra.env] config must be an inline table \
              of string values, e.g. config = { KEY = \"val\" }")
    in
    let* secret_keys =
      match Otoml.find_opt doc Otoml.get_value ["infra"; "env"; "secrets"] with
      | None -> Ok []
      | Some v ->
        (try
           Otoml.get_array Otoml.get_string v
           |> Result.ok
         with Otoml.Type_error _ ->
           validation_error path
             "sun.toml: [infra.env] secrets must be an array of strings, \
              e.g. secrets = [\"KEY1\", \"KEY2\"]")
    in

    (* [infra.deploy] *)
    let* rollout_strategy =
      match Otoml.Helpers.find_string_opt doc ["infra"; "deploy"; "rollout_strategy"] with
      | None -> Ok None
      | Some s ->
        let* strategy = parse_rollout_strategy path s in
        Ok (Some strategy)
    in
    let ingress_host =
      Otoml.Helpers.find_string_opt doc ["infra"; "deploy"; "ingress_host"]
    in
    let ingress_path =
      Otoml.Helpers.find_string_opt doc ["infra"; "deploy"; "ingress_path"]
    in

    (* [infra.labels] *)
    let* extra_labels =
      match Otoml.find_opt doc Otoml.get_value ["infra"; "labels"; "extra_labels"] with
      | None -> Ok []
      | Some v ->
        let* pairs =
          (try
             Otoml.get_table_values Otoml.get_string v
             |> Result.ok
           with Otoml.Type_error _ ->
             validation_error path
               "sun.toml: [infra.labels] extra_labels must be an inline \
                table of string values, e.g. extra_labels = { key = \"val\" }")
        in
        let rec validate_keys = function
          | [] -> Ok pairs
          | (k, _) :: rest ->
            let* () =
              validate_extra_label_key k
              |> Result.map_error (fun message -> Validation { path; message })
            in
            validate_keys rest
        in
        validate_keys pairs
    in

    (* [infra.rollout] — progressive delivery *)
    let* progressive_delivery =
      match Otoml.Helpers.find_string_opt doc ["infra"; "rollout"; "strategy"] with
      | None -> Ok None
      | Some "canary" ->
        let* steps = parse_steps path doc in
        if steps = [] then
          validation_error path
            "sun.toml: [infra.rollout] strategy \"canary\" requires at least \
             one step in steps = [...]"
        else
          Ok (Some (Canary { steps }))
      | Some "blue-green" ->
        Ok (Some Blue_green)
      | Some other ->
        validation_error path (Printf.sprintf
          "sun.toml: unsupported [infra.rollout] strategy %S — \
           valid values are \"canary\" and \"blue-green\"" other)
    in

    Ok { replicas;
         cpu;
         memory;
         env_config;
         secret_keys;
         rollout_strategy;
         ingress_host;
         ingress_path;
         extra_labels;
         progressive_delivery }
  end

let load_result path =
  try load_result path with
  | Otoml.Type_error message -> Error (Validation { path; message })

let load path =
  match load_result path with
  | Ok t -> t
  | Error err -> failwith (parse_error_to_string err)
