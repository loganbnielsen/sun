open Cmdliner

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let read_file path =
  let ic = open_in path in
  let s = In_channel.input_all ic in
  close_in ic; s

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let run_cmd ?(echo = true) cmd =
  if echo then Printf.printf "  $ %s\n%!" cmd;
  Sys.command cmd

let current_branch () =
  let tmp = Filename.temp_file "sun-br-" ".tmp" in
  ignore (Sys.command (Printf.sprintf
    "git rev-parse --abbrev-ref HEAD > %s 2>/dev/null" (Filename.quote tmp)));
  let s = String.trim (read_file tmp) in
  (try Sys.remove tmp with _ -> ());
  s

let git_branch_exists branch =
  Sys.command (Printf.sprintf
    "git rev-parse --verify %s >/dev/null 2>&1" (Filename.quote branch)) = 0

let run_cmd_lines ?(echo = false) cmd =
  let tmp = Filename.temp_file "sun-cmd-" ".tmp" in
  let full = Printf.sprintf "%s > %s 2>/dev/null" cmd tmp in
  if echo then Printf.printf "  $ %s\n%!" cmd;
  ignore (Sys.command full);
  let lines = String.split_on_char '\n' (String.trim (read_file tmp)) in
  (try Sys.remove tmp with _ -> ());
  List.filter (fun s -> s <> "") lines

(* Commit any dirty perf_baseline.json before attempting a merge so that
   "local changes would be overwritten" errors cannot block the merge. *)
let commit_dirty_baseline () =
  let dirty = run_cmd_lines
    "git status --porcelain -- tools/perf/perf_baseline.json" in
  if dirty <> [] then begin
    ignore (run_cmd ~echo:false "git add tools/perf/perf_baseline.json");
    ignore (run_cmd ~echo:false
      "git commit -m \"pipeline: checkpoint perf baseline\"")
  end

(* Resolve all auto-resolvable merge conflicts:
   - tools/perf/perf_baseline.json  → always keep main's version
   - project/tickets/**               → always restore main's state entirely
   Returns true if no unresolvable conflicts remain. *)
let resolve_merge_conflicts () =
  (* All paths that still have unmerged index entries (covers both content
     conflicts and rename/rename conflicts). *)
  let all_unmerged = run_cmd_lines
    "git ls-files --unmerged | awk '{print $4}' | sort -u" in
  let content_conflicts = run_cmd_lines
    "git diff --name-only --diff-filter=U" in

  let has_baseline = List.mem "tools/perf/perf_baseline.json" content_conflicts in
  let ticket_prefix = "project/tickets/" in
  let is_ticket_path f =
    let n = String.length ticket_prefix in
    String.length f >= n && String.sub f 0 n = ticket_prefix in
  let ticket_unmerged = List.filter is_ticket_path all_unmerged in

  if has_baseline then begin
    ignore (run_cmd ~echo:false
      "git checkout --ours -- tools/perf/perf_baseline.json");
    ignore (run_cmd ~echo:false "git add tools/perf/perf_baseline.json");
    Printf.printf "  auto-resolved tools/perf/perf_baseline.json (kept main)\n%!"
  end;

  if ticket_unmerged <> [] then begin
    (* Remove all unmerged ticket index entries, then restore exactly what
       HEAD (main) has.  This handles both content and rename/rename conflicts
       in project/tickets/ without caring which side introduced what. *)
    ignore (run_cmd ~echo:false
      "git status --porcelain -- project/tickets/ \
       | awk '{print $2}' \
       | xargs -r git rm -f --cached -- 2>/dev/null; true");
    ignore (run_cmd ~echo:false
      "git checkout HEAD -- project/tickets/ 2>/dev/null; true");
    ignore (run_cmd ~echo:false "git add -- project/tickets/ 2>/dev/null; true");
    Printf.printf "  auto-resolved %d project/tickets/ conflict(s) (restored main state)\n%!"
      (List.length ticket_unmerged)
  end;

  (* Auto-resolve dune file content conflicts with a union merge: keep all
     non-duplicate lines from both sides.  Dune build files only accumulate
     module and library names, so a union merge is always correct here. *)
  let dune_conflicts = List.filter (fun f ->
    Filename.basename f = "dune"
  ) content_conflicts in
  List.iter (fun path ->
    ignore (run_cmd ~echo:false (Printf.sprintf
      {|awk 'BEGIN{skip=0} /^<<<<<<< /{skip=1;next} /^=======$/{skip=0;next} /^>>>>>>> /{next} !seen[$0]++{print}' %s > %s.merged && mv %s.merged %s|}
      (Filename.quote path) (Filename.quote path)
      (Filename.quote path) (Filename.quote path)));
    ignore (run_cmd ~echo:false
      (Printf.sprintf "git add %s" (Filename.quote path)));
    Printf.printf "  auto-resolved %s (union merge)\n%!" path
  ) dune_conflicts;

  (* After resolution, check whether any unmerged entries remain. *)
  let remaining = run_cmd_lines
    "git ls-files --unmerged | awk '{print $4}' | sort -u" in
  let unresolvable = List.filter (fun f ->
    f <> "tools/perf/perf_baseline.json"
    && not (is_ticket_path f)
    && Filename.basename f <> "dune"
  ) remaining in

  if unresolvable <> [] then begin
    Printf.eprintf "  unresolved conflicts in: %s\n"
      (String.concat ", " unresolvable);
    false
  end else
    true

(* ── Frontmatter parser ───────────────────────────────────────────────────── *)

let parse_frontmatter content =
  match String.split_on_char '\n' content with
  | "---" :: rest ->
    let rec collect acc = function
      | [] | "---" :: _ -> acc
      | line :: rest ->
        (match String.index_opt line ':' with
         | Some i ->
           let key   = String.trim (String.sub line 0 i) in
           let value = String.trim (String.sub line (i + 1) (String.length line - i - 1)) in
           collect ((key, value) :: acc) rest
         | None -> collect acc rest)
    in
    collect [] rest
  | _ -> []

let fm_get fields key =
  match List.assoc_opt key fields with
  | Some v when v <> "" -> Some v
  | _ -> None

(* ── Ticket metadata ─────────────────────────────────────────────────────── *)

let ticket_states = [
  "BACKLOG";
  "READY_FOR_ENGINEERING";
  "IN_PROGRESS";
  "REVIEW";
  "READY_TO_MERGE";
  "BLOCKED_BY_PERFORMANCE";
  "DONE";
]

let strip_trailing_period s =
  let s = String.trim s in
  let n = String.length s in
  if n > 0 && s.[n - 1] = '.' then String.sub s 0 (n - 1) else s

let starts_with ~prefix s =
  let lp = String.length prefix in
  String.length s >= lp && String.sub s 0 lp = prefix

let contains_substring ~needle s =
  let ln = String.length needle in
  let ls = String.length s in
  if ln = 0 then true
  else if ln > ls then false
  else
    let rec go i =
      if i > ls - ln then false
      else if String.sub s i ln = needle then true
      else go (i + 1)
    in
    go 0

let parse_depends content =
  let prefix = "**Depends on:**" in
  let rec find = function
    | [] -> []
    | line :: rest ->
      let line = String.trim line in
      if starts_with ~prefix line then
        let raw =
          String.sub line (String.length prefix)
            (String.length line - String.length prefix)
          |> strip_trailing_period
        in
        if String.lowercase_ascii (String.trim raw) = "none" then []
        else
          String.split_on_char ',' raw
          |> List.map String.trim
          |> List.filter (fun s -> s <> "")
      else find rest
  in
  find (String.split_on_char '\n' content)

let has_human_decision_gate content =
  List.exists (fun marker -> contains_substring ~needle:marker content) [
    "## Decision Required";
    "## Blocked On";
    "## Open Questions";
    "**Decision required:**";
    "**Blocked on:**";
    "**Open questions:**";
    "TBD";
    "TODO(decide)";
    "NEEDS HUMAN";
  ]

let human_decision_details content =
  let lines = String.split_on_char '\n' content in
  let section_markers = [
    "## Decision Required";
    "## Blocked On";
    "## Open Questions";
    "**Decision required:**";
    "**Blocked on:**";
    "**Open questions:**";
  ] in
  let marker_lines = [
    "TBD";
    "TODO(decide)";
    "NEEDS HUMAN";
  ] in
  let is_bold_heading line =
    let line = String.trim line in
    starts_with ~prefix:"**" line && contains_substring ~needle:":**" line
  in
  let is_boundary marker line =
    let line = String.trim line in
    if starts_with ~prefix:"## " marker then
      starts_with ~prefix:"## " line && line <> marker
    else
      is_bold_heading line && line <> marker
  in
  let rec collect_section marker acc = function
    | [] -> List.rev acc
    | line :: rest ->
      let trimmed = String.trim line in
      if acc = [] && trimmed <> marker then
        collect_section marker acc rest
      else if acc <> [] && is_boundary marker trimmed then
        List.rev acc
      else
        collect_section marker (line :: acc) rest
  in
  let sections =
    section_markers
    |> List.filter_map (fun marker ->
      let section = collect_section marker [] lines in
      if section = [] then None else Some (String.concat "\n" section))
  in
  let marker_hits =
    lines
    |> List.filter (fun line ->
      List.exists (fun marker -> contains_substring ~needle:marker line) marker_lines)
  in
  String.concat "\n\n" (sections @ marker_hits)

let ticket_title content =
  let lines = String.split_on_char '\n' content in
  let after_frontmatter = function
    | "---" :: rest ->
      let rec skip = function
        | [] -> []
        | "---" :: rest -> rest
        | _ :: rest -> skip rest
      in
      skip rest
    | lines -> lines
  in
  after_frontmatter lines
  |> List.find_opt (fun line ->
       let line = String.trim line in
       line <> "" && not (starts_with ~prefix:"**Depends on:**" line))
  |> Option.map String.trim
  |> Option.value ~default:"-"

let find_ticket ticket_id =
  List.find_map (fun state ->
    let path = Printf.sprintf "project/tickets/%s/%s.md" state ticket_id in
    if Sys.file_exists path then Some (state, path) else None
  ) ticket_states

let dependency_status dep =
  match find_ticket dep with
  | None -> `Unknown
  | Some ("DONE", _) -> `Done
  | Some (state, _) -> `Blocked state

let dependency_summary deps =
  match deps with
  | [] -> "none"
  | deps -> String.concat ", " deps

let readiness_label state content =
  if has_human_decision_gate content then "needs-human"
  else
    let deps = parse_depends content in
    match List.find_opt (fun dep -> dependency_status dep <> `Done) deps with
    | Some dep ->
      (match dependency_status dep with
       | `Unknown -> "blocked: unknown " ^ dep
       | `Blocked state -> "blocked: " ^ dep ^ " in " ^ state
       | `Done -> "actionable")
    | None ->
      if state = "READY_FOR_ENGINEERING" then "actionable" else "-"

(* ── sun pipeline merge ──────────────────────────────────────────────────── *)

let run_merge dry_run ticket_filter =
  let ready_dir = "project/tickets/READY_TO_MERGE" in
  if not (Sys.file_exists ready_dir) then begin
    Printf.eprintf "error: %s not found; run from workspace root.\n" ready_dir;
    exit 1
  end;
  let files =
    Sys.readdir ready_dir |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".md")
    |> List.filter (fun f -> match ticket_filter with
       | None    -> true
       | Some id -> f = id ^ ".md")
    |> List.sort String.compare
  in
  if files = [] then begin
    (match ticket_filter with
     | Some id -> Printf.eprintf "error: %s not found in READY_TO_MERGE\n" id
     | None    -> Printf.printf "Nothing in READY_TO_MERGE.\n");
    exit 0
  end;
  let branch = current_branch () in
  if branch <> "main" then begin
    Printf.eprintf "error: must be on main to merge (currently on %s).\n" branch;
    exit 1
  end;
  let errors  = ref 0 in
  let merged  = ref [] in
  List.iter (fun filename ->
    let src    = Filename.concat ready_dir filename in
    let id     = Filename.chop_suffix filename ".md" in
    let fields = parse_frontmatter (read_file src) in
    Printf.printf "\n[%s]\n%!" id;
    match fm_get fields "branch", fm_get fields "worktree" with
    | None, _ ->
      Printf.eprintf "  no branch: in frontmatter — skipping\n"; incr errors
    | _, None ->
      Printf.eprintf "  no worktree: in frontmatter — skipping\n"; incr errors
    | Some branch, Some worktree ->
      if not (git_branch_exists branch) then begin
        Printf.eprintf "  branch %s not found — skipping\n" branch; incr errors
      end else if dry_run then begin
        Printf.printf "  (dry-run) merge %s\n" branch;
        Printf.printf "  (dry-run) remove worktree %s\n" worktree;
        Printf.printf "  (dry-run) delete branch %s\n" branch;
        Printf.printf "  (dry-run) → project/tickets/DONE/%s\n" filename
      end else begin
        (* Ensure no dirty perf_baseline.json blocks the merge. *)
        commit_dirty_baseline ();

        let merge_rc = run_cmd (Printf.sprintf
          "git merge %s --no-ff --no-edit" (Filename.quote branch)) in
        let merge_rc =
          if merge_rc <> 0 then begin
            if resolve_merge_conflicts () then
              (* All conflicts auto-resolved — continue the merge commit. *)
              run_cmd ~echo:false
                "GIT_EDITOR=true git merge --continue"
            else begin
              (* Unresolvable conflicts: abort and leave main clean. *)
              ignore (run_cmd ~echo:false "git merge --abort");
              ignore (run_cmd ~echo:false
                "git checkout HEAD -- tools/perf/perf_baseline.json 2>/dev/null; true");
              Printf.eprintf "  merge failed — aborting\n";
              1
            end
          end else merge_rc
        in
        if merge_rc <> 0 then
          incr errors
        else begin
          let perf_rc = run_cmd
            "./platform/local/scripts/run_tests.sh unit --no-infra" in
          if perf_rc >= 1 then begin
            let label = if perf_rc = 2 then "perf regression" else "test failure" in
            Printf.eprintf "  %s detected — moving to BLOCKED_BY_PERFORMANCE\n%!" label;
            let dst = Filename.concat "project/tickets/BLOCKED_BY_PERFORMANCE" filename in
            Sys.rename src dst;
            (* Commit the ticket state change atomically so main stays clean. *)
            ignore (run_cmd ~echo:false
              (Printf.sprintf
                "git add project/tickets/ && git commit -m %s"
                (Filename.quote
                  (Printf.sprintf "pipeline: %s blocked %s" label id))));
            incr errors
          end else begin
            ignore (run_cmd ~echo:false
              "./platform/local/scripts/run_tests.sh unit --no-infra --update-baseline");
            let baseline_commit_msg = Printf.sprintf
              "pipeline: update perf baseline after %s" id in
            ignore (run_cmd ~echo:false
              (Printf.sprintf "git add tools/perf/perf_baseline.json && git commit -m %s"
                (Filename.quote baseline_commit_msg)));
            if Sys.file_exists worktree then
              ignore (run_cmd (Printf.sprintf
                "git worktree remove %s --force" (Filename.quote worktree)))
            else
              Printf.printf "  worktree %s already removed\n%!" worktree;
            ignore (run_cmd ~echo:false
              (Printf.sprintf "git branch -d %s" (Filename.quote branch)));
            Sys.rename src (Filename.concat "project/tickets/DONE" filename);
            Printf.printf "  ✓  merged → DONE\n%!";
            merged := id :: !merged
          end
        end
      end
  ) files;
  if (not dry_run) && !merged <> [] then begin
    let ids = String.concat "\n" (List.map (fun id -> "- " ^ id) (List.rev !merged)) in
    let msg = Printf.sprintf "pipeline: move %d ticket(s) to DONE\n\n%s"
      (List.length !merged) ids in
    let rc = run_cmd ~echo:false
      (Printf.sprintf "git add project/tickets/ && git commit -m %s" (Filename.quote msg)) in
    if rc <> 0 then Printf.eprintf "warning: failed to commit ticket state changes\n"
  end;
  if !errors > 0 then Printf.eprintf "\n%d ticket(s) had errors.\n" !errors;
  Printf.printf "\nDone. %d merged.\n" (List.length !merged)

(* ── sun pipeline review ─────────────────────────────────────────────────── *)

type violation = { vfile: string; vline: int option; vmessage: string }

let parse_result json_str =
  let open Yojson.Basic.Util in
  let j = Yojson.Basic.from_string json_str in
  let status = match j |> member "status" |> to_string with
    | "pass" -> `Pass
    | "fail" -> `Fail
    | s -> Printf.eprintf "error: unknown status %S\n" s; exit 1
  in
  let summary = j |> member "summary" |> to_string_option |> Option.value ~default:"" in
  let violations =
    (match j |> member "violations" with
     | `Null -> []
     | v -> to_list v)
    |> List.map (fun v ->
      { vfile    = v |> member "file" |> to_string
      ; vline    = (try Some (v |> member "line" |> to_int) with _ -> None)
      ; vmessage = v |> member "message" |> to_string })
  in
  (status, summary, violations)

let format_violations vs =
  String.concat "\n" (List.map (fun v ->
    match v.vline with
    | Some l -> Printf.sprintf "- `%s:%d` — %s" v.vfile l v.vmessage
    | None   -> Printf.sprintf "- `%s` — %s" v.vfile v.vmessage
  ) vs)

let run_review ticket_id result_file =
  let src = Printf.sprintf "project/tickets/REVIEW/%s.md" ticket_id in
  if not (Sys.file_exists src) then begin
    Printf.eprintf "error: %s not found\n" src; exit 1
  end;
  let json_str =
    match result_file with
    | Some path -> read_file path
    | None ->
      let buf = Buffer.create 512 in
      (try while true do Buffer.add_channel buf stdin 4096 done
       with End_of_file -> ());
      Buffer.contents buf
  in
  let (status, summary, violations) = parse_result (String.trim json_str) in
  let content = read_file src in
  (match status with
   | `Pass ->
     let note = Printf.sprintf "\n## Review — automated checks passed\n%s\n" summary in
     let dst = Printf.sprintf "project/tickets/READY_TO_MERGE/%s.md" ticket_id in
     write_file src (content ^ note);
     Sys.rename src dst;
     Printf.printf "[%s] → READY_TO_MERGE\n" ticket_id
   | `Fail ->
     let note = Printf.sprintf "\n## Review — returned for revision\n%s\n"
       (format_violations violations) in
     let dst = Printf.sprintf "project/tickets/READY_FOR_ENGINEERING/%s.md" ticket_id in
     write_file src (content ^ note);
     Sys.rename src dst;
     Printf.printf "[%s] → READY_FOR_ENGINEERING  (%d violation(s))\n"
       ticket_id (List.length violations))

(* ── sun pipeline ls ─────────────────────────────────────────────────────── *)

let run_ls include_done =
  let states = if include_done then ticket_states
               else List.filter (fun s -> s <> "DONE") ticket_states in
  let any = ref false in
  List.iter (fun state ->
    let dir = "project/tickets/" ^ state in
    if Sys.file_exists dir then begin
      let files =
        Sys.readdir dir |> Array.to_list
        |> List.filter (fun f -> Filename.check_suffix f ".md")
        |> List.sort String.compare
      in
      if files <> [] then begin
        any := true;
        Printf.printf "\n%s (%d)\n" state (List.length files);
        List.iter (fun filename ->
          let id     = Filename.chop_suffix filename ".md" in
          let content = read_file (Filename.concat dir filename) in
          let fields = parse_frontmatter content in
          let typ     = fm_get fields "type"     |> Option.value ~default:"-" in
          let sev     = fm_get fields "severity" |> Option.value ~default:"-" in
          let deps    = parse_depends content |> dependency_summary in
          let ready   = readiness_label state content in
          let title   = ticket_title content in
          Printf.printf "  %-12s  %-18s  %-7s  depends on: %-24s  %-24s  %s\n"
            id typ sev deps ready title
        ) files
      end
    end
  ) states;
  if not !any then Printf.printf "No tickets found.\n"

(* ── sun pipeline check ──────────────────────────────────────────────────── *)

let run_check ticket_id =
  match find_ticket ticket_id with
  | None ->
    Printf.eprintf "unknown ticket: %s\n" ticket_id;
    exit 2
  | Some (state, path) ->
    let content = read_file path in
    let deps = parse_depends content in
    Printf.printf "%s  state: %s\n" ticket_id state;
    Printf.printf "depends on: %s\n" (dependency_summary deps);
    if has_human_decision_gate content then begin
      let details = human_decision_details content in
      if String.trim details <> "" then
        Printf.printf "\n%s\n\n" details;
      Printf.printf "status: blocked-for-human-decision\n";
      exit 1
    end;
    let blocked =
      deps
      |> List.filter_map (fun dep ->
        match dependency_status dep with
        | `Done -> None
        | `Unknown -> Some (dep, "UNKNOWN")
        | `Blocked state -> Some (dep, state))
    in
    if blocked <> [] then begin
      List.iter (fun (dep, state) ->
        Printf.printf "blocked by dependency: %s in %s\n" dep state
      ) blocked;
      Printf.printf "status: blocked-by-dependency\n";
      exit 1
    end;
    if state = "READY_FOR_ENGINEERING" then
      Printf.printf "status: actionable\n"
    else begin
      Printf.printf "status: not-ready-state\n";
      exit 1
    end

(* ── Cmdliner ────────────────────────────────────────────────────────────── *)

let dry_run_flag =
  Arg.(value & flag & info ["dry-run"]
    ~doc:"Print what would happen without making changes")

let merge_ticket_arg =
  Arg.(value & pos 0 (some string) None &
       info [] ~docv:"TICKET-ID"
         ~doc:"Ticket to merge (e.g. EXP-005). Omit to merge all READY_TO_MERGE tickets.")

let merge_cmd =
  Cmd.v
    (Cmd.info "merge"
       ~doc:"Merge READY_TO_MERGE tickets into main, remove worktrees, move to DONE. \
             Pass a ticket ID to merge one; omit to merge all.")
    Term.(const run_merge $ dry_run_flag $ merge_ticket_arg)

let ticket_arg =
  Arg.(required & pos 0 (some string) None &
       info [] ~docv:"TICKET-ID" ~doc:"e.g. EXP-005")

let result_file_arg =
  Arg.(value & opt (some string) None &
       info ["result-file"; "f"] ~docv:"PATH"
         ~doc:"JSON review result file (default: read stdin)")

let review_cmd =
  Cmd.v
    (Cmd.info "review"
       ~doc:"Process a structured JSON review result, moving the ticket to \
             READY_TO_MERGE or READY_FOR_ENGINEERING")
    Term.(const run_review $ ticket_arg $ result_file_arg)

let include_done_flag =
  Arg.(value & flag & info ["all"; "a"]
    ~doc:"Include DONE tickets in the listing")

let ls_cmd =
  Cmd.v
    (Cmd.info "ls"
       ~doc:"List tickets grouped by pipeline stage. Pass --all to include DONE.")
    Term.(const run_ls $ include_done_flag)

let check_cmd =
  Cmd.v
    (Cmd.info "check"
       ~doc:"Check whether a ticket is actionable, including human-decision \
             gates and dependency status.")
    Term.(const run_check $ ticket_arg)

let cmd =
  Cmd.group
    (Cmd.info "pipeline"
       ~doc:"Deterministic pipeline operations: merge tickets, process review results, list status")
    [ ls_cmd; check_cmd; merge_cmd; review_cmd ]
