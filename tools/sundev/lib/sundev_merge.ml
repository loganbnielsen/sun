let read_file  = Sundev_shell.read_file

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let current_branch () =
  Sun_process.output ~echo:false "git rev-parse --abbrev-ref HEAD 2>/dev/null"

let git_branch_exists branch =
  Sun_process.run_rc ~echo:false
    (Printf.sprintf "git rev-parse --verify %s >/dev/null 2>&1" (Filename.quote branch)) = 0

let commit_dirty_baseline () =
  let dirty = Sundev_shell.run_cmd_lines
    "git status --porcelain -- tools/perf/perf_baseline.json" in
  if dirty <> [] then begin
    ignore (Sundev_shell.run_cmd ~echo:false "git add tools/perf/perf_baseline.json");
    ignore (Sundev_shell.run_cmd ~echo:false
      "git commit -m \"pipeline: checkpoint perf baseline\"")
  end

let restore_baseline_to_head () =
  ignore (Sundev_shell.run_cmd ~echo:false
    "git checkout HEAD -- tools/perf/perf_baseline.json 2>/dev/null; true")

let revert_merge_commit ticket_id reason =
  restore_baseline_to_head ();
  let rc = Sundev_shell.run_cmd ~echo:false
    "SUN_SKIP_HOOKS=1 git revert -m 1 --no-edit HEAD >/dev/null 2>&1" in
  if rc = 0 then begin
    Printf.eprintf "  reverted merge commit for %s after %s; main code is unchanged\n%!"
      ticket_id reason;
    true
  end else begin
    Printf.eprintf
      "  failed to revert merge commit for %s after %s — manual cleanup required\n%!"
      ticket_id reason;
    false
  end

(* Resolve all auto-resolvable merge conflicts.
   Returns true when no unresolvable conflicts remain. *)
let resolve_merge_conflicts () =
  let all_unmerged = Sundev_shell.run_cmd_lines
    "git ls-files --unmerged | awk '{print $4}' | sort -u" in
  let content_conflicts = Sundev_shell.run_cmd_lines
    "git diff --name-only --diff-filter=U" in
  let ticket_prefix = "project/tickets/" in
  let is_ticket_path f =
    let n = String.length ticket_prefix in
    String.length f >= n && String.sub f 0 n = ticket_prefix
  in
  let ticket_unmerged = List.filter is_ticket_path all_unmerged in

  if List.mem "tools/perf/perf_baseline.json" content_conflicts then begin
    ignore (Sundev_shell.run_cmd ~echo:false
      "git checkout --ours -- tools/perf/perf_baseline.json");
    ignore (Sundev_shell.run_cmd ~echo:false "git add tools/perf/perf_baseline.json");
    Printf.printf "  auto-resolved tools/perf/perf_baseline.json (kept main)\n%!"
  end;

  if ticket_unmerged <> [] then begin
    ignore (Sundev_shell.run_cmd ~echo:false
      "git status --porcelain -- project/tickets/ \
       | awk '{print $2}' \
       | xargs -r git rm -f --cached -- 2>/dev/null; true");
    ignore (Sundev_shell.run_cmd ~echo:false
      "git checkout HEAD -- project/tickets/ 2>/dev/null; true");
    ignore (Sundev_shell.run_cmd ~echo:false "git add -- project/tickets/ 2>/dev/null; true");
    Printf.printf "  auto-resolved %d project/tickets/ conflict(s) (restored main state)\n%!"
      (List.length ticket_unmerged)
  end;

  List.iter (fun path ->
    if Filename.basename path = "dune" then begin
      ignore (Sundev_shell.run_cmd ~echo:false (Printf.sprintf
        {|awk 'BEGIN{skip=0} /^<<<<<<< /{skip=1;next} /^=======$/{skip=0;next} /^>>>>>>> /{next} !seen[$0]++{print}' %s > %s.merged && mv %s.merged %s|}
        (Filename.quote path) (Filename.quote path)
        (Filename.quote path) (Filename.quote path)));
      ignore (Sundev_shell.run_cmd ~echo:false
        (Printf.sprintf "git add %s" (Filename.quote path)));
      Printf.printf "  auto-resolved %s (union merge)\n%!" path
    end
  ) content_conflicts;

  let remaining = Sundev_shell.run_cmd_lines
    "git ls-files --unmerged | awk '{print $4}' | sort -u" in
  let unresolvable = List.filter (fun f ->
    f <> "tools/perf/perf_baseline.json"
    && not (is_ticket_path f)
    && Filename.basename f <> "dune"
  ) remaining in
  if unresolvable <> [] then begin
    Printf.eprintf "  unresolved conflicts in: %s\n" (String.concat ", " unresolvable);
    false
  end else
    true

(* ── pipeline merge ──────────────────────────────────────────────────────── *)

let run_merge dry_run accept_performance_regression ticket_filter =
  let ready_dir = "project/tickets/READY_TO_MERGE" in
  if not (Sys.file_exists ready_dir) then begin
    Printf.eprintf "error: %s not found; run from workspace root.\n" ready_dir; exit 1
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
    Printf.eprintf "error: must be on main to merge (currently on %s).\n" branch; exit 1
  end;
  let errors = ref 0 in
  let merged = ref [] in
  List.iter (fun filename ->
    let src    = Filename.concat ready_dir filename in
    let id     = Filename.chop_suffix filename ".md" in
    let fields = Sundev_ticket.parse_frontmatter (read_file src) in
    Printf.printf "\n[%s]\n%!" id;
    match Sundev_ticket.fm_get fields "branch", Sundev_ticket.fm_get fields "worktree" with
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
        commit_dirty_baseline ();
        let merge_rc = Sundev_shell.run_cmd (Printf.sprintf
          "git merge %s --no-ff --no-edit" (Filename.quote branch)) in
        let merge_rc =
          if merge_rc <> 0 then begin
            if resolve_merge_conflicts () then
              Sundev_shell.run_cmd ~echo:false "GIT_EDITOR=true git merge --continue"
            else begin
              ignore (Sundev_shell.run_cmd ~echo:false "git merge --abort");
              ignore (Sundev_shell.run_cmd ~echo:false
                "git checkout HEAD -- tools/perf/perf_baseline.json 2>/dev/null; true");
              Printf.eprintf "  merge failed — aborting\n";
              1
            end
          end else merge_rc
        in
        if merge_rc <> 0 then incr errors
        else begin
          let perf_rc = Sundev_shell.run_cmd "./platform/local/scripts/run_tests.sh" in
          if perf_rc = 2 && accept_performance_regression then begin
            Printf.eprintf "  perf regression explicitly accepted — recording new baseline\n%!";
            ignore (Sundev_shell.run_cmd ~echo:false
              "./platform/local/scripts/run_tests.sh --update-baseline");
            ignore (Sundev_shell.run_cmd ~echo:false
              (Printf.sprintf "git add tools/perf/perf_baseline.json && git commit -m %s"
                (Filename.quote
                  (Printf.sprintf "pipeline: accept perf regression baseline after %s" id))));
            if Sys.file_exists worktree then
              ignore (Sundev_shell.run_cmd (Printf.sprintf
                "git worktree remove %s --force" (Filename.quote worktree)))
            else Printf.printf "  worktree %s already removed\n%!" worktree;
            ignore (Sundev_shell.run_cmd ~echo:false
              (Printf.sprintf "git branch -d %s" (Filename.quote branch)));
            Sys.rename src (Filename.concat "project/tickets/DONE" filename);
            Printf.printf "  ✓  merged → DONE\n%!";
            merged := id :: !merged
          end else if perf_rc >= 1 then begin
            let label = if perf_rc = 2 then "perf regression" else "test failure" in
            let reverted = revert_merge_commit id label in
            Printf.eprintf "  %s detected — moving to BLOCKED_BY_PERFORMANCE\n%!" label;
            Sys.rename src (Filename.concat "project/tickets/BLOCKED_BY_PERFORMANCE" filename);
            ignore (Sundev_shell.run_cmd ~echo:false
              (Printf.sprintf "git add project/tickets/ && git commit -m %s"
                (Filename.quote (Printf.sprintf "pipeline: %s blocked %s" label id))));
            if not reverted then
              Printf.eprintf "  warning: %s remains merged because automatic revert failed\n%!" id;
            incr errors
          end else begin
            ignore (Sundev_shell.run_cmd ~echo:false
              "./platform/local/scripts/run_tests.sh --update-baseline");
            ignore (Sundev_shell.run_cmd ~echo:false
              (Printf.sprintf "git add tools/perf/perf_baseline.json && git commit -m %s"
                (Filename.quote
                  (Printf.sprintf "pipeline: update perf baseline after %s" id))));
            if Sys.file_exists worktree then
              ignore (Sundev_shell.run_cmd (Printf.sprintf
                "git worktree remove %s --force" (Filename.quote worktree)))
            else Printf.printf "  worktree %s already removed\n%!" worktree;
            ignore (Sundev_shell.run_cmd ~echo:false
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
    let rc = Sundev_shell.run_cmd ~echo:false
      (Printf.sprintf "git add project/tickets/ && git commit -m %s" (Filename.quote msg)) in
    if rc <> 0 then Printf.eprintf "warning: failed to commit ticket state changes\n"
  end;
  if !errors > 0 then Printf.eprintf "\n%d ticket(s) had errors.\n" !errors;
  Printf.printf "\nDone. %d merged.\n" (List.length !merged)

(* ── pipeline review ─────────────────────────────────────────────────────── *)

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
      (try while true do Buffer.add_channel buf stdin 4096 done with End_of_file -> ());
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

(* ── pipeline ls ─────────────────────────────────────────────────────────── *)

let run_ls include_done =
  let states = if include_done then Sundev_ticket.ticket_states
               else List.filter (fun s -> s <> "DONE") Sundev_ticket.ticket_states in
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
          let id      = Filename.chop_suffix filename ".md" in
          let content = read_file (Filename.concat dir filename) in
          let fields  = Sundev_ticket.parse_frontmatter content in
          let typ     = Sundev_ticket.fm_get fields "type"     |> Option.value ~default:"-" in
          let sev     = Sundev_ticket.fm_get fields "severity" |> Option.value ~default:"-" in
          let deps    = Sundev_ticket.parse_depends content |> Sundev_ticket.dependency_summary in
          let ready   = Sundev_ticket.readiness_label state content in
          let title   = Sundev_ticket.ticket_title content in
          Printf.printf "  %-12s  %-18s  %-7s  depends on: %-24s  %-24s  %s\n"
            id typ sev deps ready title
        ) files
      end
    end
  ) states;
  if not !any then Printf.printf "No tickets found.\n"

(* ── pipeline check ──────────────────────────────────────────────────────── *)

let run_check ticket_id =
  match Sundev_ticket.find_ticket ticket_id with
  | None ->
    Printf.eprintf "unknown ticket: %s\n" ticket_id; exit 2
  | Some (state, path) ->
    let content = read_file path in
    let deps = Sundev_ticket.parse_depends content in
    Printf.printf "%s  state: %s\n" ticket_id state;
    Printf.printf "depends on: %s\n" (Sundev_ticket.dependency_summary deps);
    if Sundev_ticket.has_human_decision_gate content then begin
      let details = Sundev_ticket.human_decision_details content in
      if String.trim details <> "" then Printf.printf "\n%s\n\n" details;
      Printf.printf "status: blocked-for-human-decision\n";
      exit 1
    end;
    let blocked =
      deps |> List.filter_map (fun dep ->
        match Sundev_ticket.dependency_status dep with
        | `Done -> None
        | `Unknown -> Some (dep, "UNKNOWN")
        | `Blocked state -> Some (dep, state))
    in
    if blocked <> [] then begin
      List.iter (fun (dep, state) ->
        Printf.printf "blocked by dependency: %s in %s\n" dep state) blocked;
      Printf.printf "status: blocked-by-dependency\n";
      exit 1
    end;
    if state = "READY_FOR_ENGINEERING" then
      Printf.printf "status: actionable\n"
    else begin
      Printf.printf "status: not-ready-state\n"; exit 1
    end
