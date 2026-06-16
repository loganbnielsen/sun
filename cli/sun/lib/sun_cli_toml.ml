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

(* ── Validation ──────────────────────────────────────────────────────────── *)

let parse_rollout_strategy s =
  match s with
  | "Recreate"      -> Recreate
  | "RollingUpdate" -> RollingUpdate
  | other ->
    failwith (Printf.sprintf
      "sun.toml: unsupported rollout_strategy %S — \
       valid values are \"Recreate\" and \"RollingUpdate\"" other)

(* Guard: keys starting with "sun.dev/" are reserved for Sun internals. *)
let validate_extra_label_key k =
  let prefix = "sun.dev/" in
  if String.starts_with ~prefix k then
    failwith (Printf.sprintf
      "sun.toml: extra_labels key %S is reserved — \
       keys may not start with \"sun.dev/\"" k)

let validate_weight n =
  if n < 0 || n > 100 then
    failwith (Printf.sprintf
      "sun.toml: [infra.rollout] canary weight %d is invalid — \
       weights must be between 0 and 100" n)

let validate_duration d =
  if d <= 0 then
    failwith (Printf.sprintf
      "sun.toml: [infra.rollout] pause duration %d is invalid — \
       durations must be positive seconds" d)

let validate_canary_step = function
  | Weight n ->
    validate_weight n
  | Pause None ->
    ()
  | Pause (Some d) ->
    validate_duration d

(* ── Canary step parsing ─────────────────────────────────────────────────── *)

(* Parse a single step TOML value (an inline table).
   Accepts: {weight = 10}, {pause = {}}, {pause = {duration = 60}}.
   The weight-only shorthand [10, 40, 100] is handled at the array level below. *)
let parse_canary_step_value v =
  (* An inline table with either a "weight" or "pause" key *)
  let pairs =
    try Otoml.get_table v
    with Otoml.Type_error _ ->
      failwith "sun.toml: [infra.rollout] canary step must be an inline table \
                like {weight = 10} or {pause = {}}"
  in
  match List.assoc_opt "weight" pairs with
  | Some wv ->
    let n =
      try Otoml.get_integer wv
      with Otoml.Type_error _ ->
        failwith "sun.toml: [infra.rollout] canary weight must be an integer"
    in
    let step = Weight n in
    validate_canary_step step;
    step
  | None ->
    (match List.assoc_opt "pause" pairs with
     | Some pv ->
       let inner =
         try Otoml.get_table pv
         with Otoml.Type_error _ ->
           failwith "sun.toml: [infra.rollout] pause value must be an inline table \
                     like {} or {duration = 60}"
       in
       let step =
         match List.assoc_opt "duration" inner with
         | Some dv ->
           let d =
             try Otoml.get_integer dv
             with Otoml.Type_error _ ->
               failwith "sun.toml: [infra.rollout] pause duration must be an integer"
           in
           Pause (Some d)
         | None ->
           Pause None
       in
       validate_canary_step step;
       step
     | None ->
       failwith "sun.toml: unsupported [infra.rollout] canary step — \
                 expected {weight = N} or {pause = {...}}")

(* Parse the steps array. Supports:
   - Integer shorthand: steps = [10, 40, 100]  (each int → Weight n)
   - Table steps: steps = [{weight = 10}, {pause = {}}, ...]
   Mixed arrays (some ints, some tables) are rejected by the TOML parser. *)
let parse_steps doc =
  match Otoml.find_opt doc Otoml.get_value ["infra"; "rollout"; "steps"] with
  | None -> []
  | Some arr_v ->
    let items =
      try Otoml.get_array Otoml.get_value arr_v
      with Otoml.Type_error _ ->
        failwith "sun.toml: [infra.rollout] steps must be an array"
    in
    List.map (fun item ->
      match item with
      | Otoml.TomlInteger n ->
        let step = Weight n in
        validate_canary_step step;
        step
      | _ ->
        parse_canary_step_value item
    ) items

(* ── Loader ──────────────────────────────────────────────────────────────── *)

let load path =
  if not (Sys.file_exists path) then empty
  else begin
    let doc =
      match Otoml.Parser.from_file_result path with
      | Ok d -> d
      | Error msg ->
        failwith (Printf.sprintf "sun.toml: %s" msg)
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
    let env_config =
      match Otoml.find_opt doc Otoml.get_value ["infra"; "env"; "config"] with
      | None -> []
      | Some v ->
        (try
           Otoml.get_table_values Otoml.get_string v
         with Otoml.Type_error _ ->
           failwith "sun.toml: [infra.env] config must be an inline table \
                     of string values, e.g. config = { KEY = \"val\" }")
    in
    let secret_keys =
      match Otoml.find_opt doc Otoml.get_value ["infra"; "env"; "secrets"] with
      | None -> []
      | Some v ->
        (try
           Otoml.get_array Otoml.get_string v
         with Otoml.Type_error _ ->
           failwith "sun.toml: [infra.env] secrets must be an array of strings, \
                     e.g. secrets = [\"KEY1\", \"KEY2\"]")
    in

    (* [infra.deploy] *)
    let rollout_strategy =
      match Otoml.Helpers.find_string_opt doc ["infra"; "deploy"; "rollout_strategy"] with
      | None -> None
      | Some s -> Some (parse_rollout_strategy s)
    in
    let ingress_host =
      Otoml.Helpers.find_string_opt doc ["infra"; "deploy"; "ingress_host"]
    in
    let ingress_path =
      Otoml.Helpers.find_string_opt doc ["infra"; "deploy"; "ingress_path"]
    in

    (* [infra.labels] *)
    let extra_labels =
      match Otoml.find_opt doc Otoml.get_value ["infra"; "labels"; "extra_labels"] with
      | None -> []
      | Some v ->
        let pairs =
          (try
             Otoml.get_table_values Otoml.get_string v
           with Otoml.Type_error _ ->
             failwith "sun.toml: [infra.labels] extra_labels must be an inline \
                       table of string values, e.g. extra_labels = { key = \"val\" }")
        in
        List.iter (fun (k, _) -> validate_extra_label_key k) pairs;
        pairs
    in

    (* [infra.rollout] — progressive delivery *)
    let progressive_delivery =
      match Otoml.Helpers.find_string_opt doc ["infra"; "rollout"; "strategy"] with
      | None -> None
      | Some "canary" ->
        let steps = parse_steps doc in
        if steps = [] then
          failwith "sun.toml: [infra.rollout] strategy \"canary\" requires at least \
                    one step in steps = [...]";
        Some (Canary { steps })
      | Some "blue-green" ->
        Some Blue_green
      | Some other ->
        failwith (Printf.sprintf
          "sun.toml: unsupported [infra.rollout] strategy %S — \
           valid values are \"canary\" and \"blue-green\"" other)
    in

    { replicas;
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
