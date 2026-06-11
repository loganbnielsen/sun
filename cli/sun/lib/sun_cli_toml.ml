(* Minimal parser for sun.toml — only the fields sun up/deploy care about.
   Handles the subset of TOML used by Sun's infra block:
     [infra.scale]    replicas, cpu, memory
     [infra.env]      config = { KEY = "val", ... }  (inline table only)
                      secrets = ["KEY", ...]
     [infra.deploy]   rollout_strategy, ingress_host, ingress_path
     [infra.labels]   extra_labels = { key = "val", ... }  (inline table only)
     [infra.rollout]  strategy, steps (progressive delivery via Argo Rollouts)
   Everything else is silently ignored (forward-compatible). *)

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

(* ── Low-level helpers ───────────────────────────────────────────────────── *)

let starts_with s prefix =
  let n = String.length prefix in
  String.length s >= n && String.sub s 0 n = prefix

(* Extract first "..." quoted string from a line *)
let quoted_string line =
  match String.index_opt line '"' with
  | None -> None
  | Some i ->
    (match String.index_from_opt line (i + 1) '"' with
     | None -> None
     | Some j -> Some (String.sub line (i + 1) (j - i - 1)))

(* Extract integer from "key = 42" *)
let int_after_eq line =
  match String.index_opt line '=' with
  | None -> None
  | Some i ->
    let v = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
    (try Some (int_of_string v) with _ -> None)

(* Strip surrounding double-quotes from a key token if present.
   TOML allows both bare keys (APP_ENV) and quoted keys ("sun.dev/owner"). *)
let unquote_key s =
  let n = String.length s in
  if n >= 2 && s.[0] = '"' && s.[n-1] = '"'
  then String.sub s 1 (n - 2)
  else s

(* Parse { KEY = "val", KEY2 = "val2" } inline table.
   Supports both bare keys and double-quoted keys.
   Returns [] on any parse failure — never raises. *)
let parse_inline_table line =
  match String.index_opt line '{', String.rindex_opt line '}' with
  | Some lo, Some hi when hi > lo ->
    let inner = String.sub line (lo + 1) (hi - lo - 1) in
    let pairs  = String.split_on_char ',' inner in
    List.filter_map (fun pair ->
      match String.index_opt pair '=' with
      | None -> None
      | Some i ->
        let k = unquote_key (String.trim (String.sub pair 0 i)) in
        let rest = String.trim (String.sub pair (i + 1) (String.length pair - i - 1)) in
        (* rest is either "value" or value without quotes *)
        (match quoted_string ("x = " ^ rest) with
         | Some v -> if k = "" then None else Some (k, v)
         | None   -> None)
    ) pairs
  | _ -> []

let parse_string_list line =
  match String.index_opt line '[', String.rindex_opt line ']' with
  | Some lo, Some hi when hi > lo ->
    let inner = String.sub line (lo + 1) (hi - lo - 1) in
    let parts = String.split_on_char ',' inner in
    List.filter_map (fun part ->
      let token = String.trim part in
      match quoted_string ("x = " ^ token) with
      | Some s when s <> "" -> Some s
      | _ -> None
    ) parts
  | _ -> []

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
  if starts_with k "sun.dev/" then
    failwith (Printf.sprintf
      "sun.toml: extra_labels key %S is reserved — \
       keys may not start with \"sun.dev/\"" k)

(* ── [rollout] section parsing ──────────────────────────────────────────── *)

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

(* Parse a single canary step inline table fragment.
   Accepts: {weight = 10}, {pause = {}}, {pause = {duration = 60}}.
   The roadmap shorthand steps = [10, 40, 100] is handled separately below. *)
let parse_canary_step_inner inner =
  (* Look for "weight" key *)
  if starts_with (String.trim inner) "weight" then begin
    (* Extract the integer after "weight =" *)
    match int_after_eq inner with
    | Some n -> Some (Weight n)
    | None   -> failwith "sun.toml: invalid [infra.rollout] canary weight step"
  end
  (* Look for "pause" key *)
  else if starts_with (String.trim inner) "pause" then begin
    (* Find the nested braces: pause = { ... } *)
    (match String.index_opt inner '{', String.rindex_opt inner '}' with
     | Some lo, Some hi when hi > lo ->
       let nested = String.trim (String.sub inner (lo + 1) (hi - lo - 1)) in
       if nested = "" then
         Some (Pause None)
       else begin
         (* Look for duration = <int> inside nested braces *)
         (match int_after_eq nested with
          | Some d -> Some (Pause (Some d))
          | None   -> failwith "sun.toml: invalid [infra.rollout] pause duration")
       end
     | _ -> Some (Pause None))
  end
  else failwith "sun.toml: unsupported [infra.rollout] canary step"

let parse_weight_steps inner =
  let parts = String.split_on_char ',' inner in
  List.filter_map (fun part ->
    let token = String.trim part in
    if token = "" then None
    else
      try Some (Weight (int_of_string token))
      with _ ->
        failwith (Printf.sprintf
          "sun.toml: invalid [infra.rollout] canary step %S — \
           use integer weights or inline step tables" token)
  ) parts

(* Parse the steps array value from a "steps = [...]" line.
   Handles the roadmap shorthand [10, 40, 100] and the extended form
   [{weight = 10}, {pause = {}}, {weight = 50}, ...]. *)
let parse_steps_array line =
  (* Find outer [ ... ] *)
  match String.index_opt line '[', String.rindex_opt line ']' with
  | None, _ | _, None -> []
  | Some lo, Some hi when hi <= lo -> []
  | Some lo, Some hi ->
    let inner = String.sub line (lo + 1) (hi - lo - 1) in
    let inner_trimmed = String.trim inner in
    if inner_trimmed = "" then []
    else if not (String.contains inner_trimmed '{') then begin
      let steps = parse_weight_steps inner_trimmed in
      List.iter validate_canary_step steps;
      steps
    end else begin
    (* Split on "}, {" to separate step objects.
       We reconstruct each step as "{...}" for parse_canary_step_inner. *)
    (* Simple approach: scan for top-level { } pairs *)
    let len     = String.length inner in
    let steps   = ref [] in
    let depth   = ref 0 in
    let start   = ref (-1) in
    for i = 0 to len - 1 do
      match inner.[i] with
      | '{' ->
        if !depth = 0 then start := i + 1;
        incr depth
      | '}' ->
        decr depth;
        if !depth = 0 && !start >= 0 then begin
          let content = String.sub inner !start (i - !start) in
          (match parse_canary_step_inner content with
           | Some step ->
             validate_canary_step step;
             steps := step :: !steps
           | None -> ());
          start := -1
        end
      | _ -> ()
    done;
    List.rev !steps
    end

(* ── Loader ──────────────────────────────────────────────────────────────── *)

let load path =
  if not (Sys.file_exists path) then empty
  else begin
    let ic = open_in path in
    let lines = ref [] in
    (try while true do lines := input_line ic :: !lines done
     with End_of_file -> ());
    close_in ic;

    let cfg            = ref empty in
    let section        = ref "" in
    (* Accumulate rollout fields before finalising progressive_delivery *)
    let rollout_strategy_str = ref None in
    let rollout_steps        = ref [] in

    List.iter (fun raw ->
      let line = String.trim raw in
      if line = "" || line.[0] = '#' then ()
      else if line.[0] = '[' then begin
        (* Section header — strip [ and ] *)
        let inner = String.trim (String.sub line 1 (String.length line - 2)) in
        section := inner
      end else
        match !section with
        | "infra.scale" ->
          if starts_with line "replicas" then
            (match int_after_eq line with
             | Some n -> cfg := { !cfg with replicas = Some n }
             | None   -> ())
          else if starts_with line "cpu" then
            (match quoted_string line with
             | Some s -> cfg := { !cfg with cpu = Some s }
             | None   -> ())
          else if starts_with line "memory" then
            (match quoted_string line with
             | Some s -> cfg := { !cfg with memory = Some s }
             | None   -> ())
        | "infra.env" ->
          if starts_with line "config" then
            cfg := { !cfg with env_config = !cfg.env_config @ parse_inline_table line }
          else if starts_with line "secrets" then
            cfg := { !cfg with secret_keys = !cfg.secret_keys @ parse_string_list line }
        | "infra.deploy" ->
          if starts_with line "rollout_strategy" then
            (match quoted_string line with
             | Some s -> cfg := { !cfg with rollout_strategy = Some (parse_rollout_strategy s) }
             | None   -> ())
          else if starts_with line "ingress_host" then
            (match quoted_string line with
             | Some s -> cfg := { !cfg with ingress_host = Some s }
             | None   -> ())
          else if starts_with line "ingress_path" then
            (match quoted_string line with
             | Some s -> cfg := { !cfg with ingress_path = Some s }
             | None   -> ())
        | "infra.labels" ->
          if starts_with line "extra_labels" then begin
            let pairs = parse_inline_table line in
            List.iter (fun (k, _) -> validate_extra_label_key k) pairs;
            cfg := { !cfg with extra_labels = !cfg.extra_labels @ pairs }
          end
        | "infra.rollout" ->
          if starts_with line "strategy" then
            (match quoted_string line with
             | Some s -> rollout_strategy_str := Some s
             | None   -> ())
          else if starts_with line "steps" then
            rollout_steps := parse_steps_array line
        | _ -> ()
    ) (List.rev !lines);

    (* Finalise progressive_delivery from accumulated rollout fields *)
    (match !rollout_strategy_str with
     | None -> ()
     | Some "canary" ->
       let steps = !rollout_steps in
       if steps = [] then
         failwith "sun.toml: [infra.rollout] strategy \"canary\" requires at least one step in steps = [...]";
       cfg := { !cfg with progressive_delivery = Some (Canary { steps }) }
     | Some "blue-green" ->
       cfg := { !cfg with progressive_delivery = Some Blue_green }
     | Some other ->
       failwith (Printf.sprintf
         "sun.toml: unsupported [infra.rollout] strategy %S — \
          valid values are \"canary\" and \"blue-green\"" other));

    !cfg
  end
