(* Minimal YAML emitter for structured Kubernetes manifest generation.
   Produces spec-compliant YAML without relying on external YAML libraries.
   All string quoting is handled through a single entry point so there is
   exactly one quoting/escaping implementation in the codebase. *)

(* ── Scalar quoting ──────────────────────────────────────────────────────── *)

(* Characters that force double-quoting when present anywhere in a value. *)
let needs_quoting s =
  let n = String.length s in
  if n = 0 then true
  else begin
    (* Leading characters that would be misinterpreted without quoting *)
    let first = s.[0] in
    let leading_special =
      first = ':' || first = '#' || first = '&' || first = '*'
      || first = '?' || first = '|' || first = '-' || first = '<'
      || first = '>' || first = '=' || first = '!' || first = '\''
      || first = '"' || first = '{' || first = '}' || first = '['
      || first = ']' || first = ',' || first = '@' || first = '`'
    in
    if leading_special then true
    else begin
      (* Scan for embedded special characters *)
      let found = ref false in
      for i = 0 to n - 1 do
        let c = s.[i] in
        if c = ':' || c = '#' || c = '"' || c = '\'' || c = '\n'
           || c = '\r' || c = '\\'
        then found := true
      done;
      if !found then true
      (* YAML "core schema" boolean / null / special scalars that must be quoted
         when used as string values *)
      else match String.lowercase_ascii s with
        | "true" | "false" | "yes" | "no" | "on" | "off" | "null" | "~" ->
          true
        | _ ->
          (* Looks like an integer or float — quote to preserve string type *)
          let all_numeric = ref true in
          let has_digit = ref false in
          let dot_count = ref 0 in
          String.iter (fun c ->
            if c >= '0' && c <= '9' then has_digit := true
            else if c = '.' then incr dot_count
            else if c = '-' || c = '+' then ()   (* leading sign *)
            else all_numeric := false
          ) s;
          !all_numeric && !has_digit && !dot_count <= 1
    end
  end

(* Emit a scalar value.
   - If the string does not need quoting, emit it bare.
   - Otherwise wrap in double quotes and escape special characters using
     standard JSON-compatible escapes (backslash-n, backslash-t, etc.). *)
let emit_scalar s =
  if not (needs_quoting s) then s
  else begin
    let buf = Buffer.create (String.length s + 4) in
    Buffer.add_char buf '"';
    String.iter (fun c ->
      match c with
      | '"'  -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c    -> Buffer.add_char buf c
    ) s;
    Buffer.add_char buf '"';
    Buffer.contents buf
  end
