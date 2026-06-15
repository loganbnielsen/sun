type handler = Request.t -> Response.t

type t =
  { method_  : Request.method_
  ; pattern  : string
  ; auth     : Auth.level
  ; handler  : handler
  }

let make m pattern ~auth handler = { method_ = m; pattern; auth; handler }

let get    p ~auth h = make `GET    p ~auth h
let post   p ~auth h = make `POST   p ~auth h
let put    p ~auth h = make `PUT    p ~auth h
let patch  p ~auth h = make `PATCH  p ~auth h
let delete p ~auth h = make `DELETE p ~auth h

(* ── Path parsing and matching ───────────────────────────────────────────── *)

(* Percent-decode a path segment value.
   Applied to route parameter values so handlers receive decoded strings.
   Literal pattern segments are matched raw (not decoded) for simplicity.
   '+' is NOT decoded as a space — this is path decoding, not form-data. *)
let percent_decode s =
  let len = String.length s in
  let buf = Buffer.create len in
  let i = ref 0 in
  while !i < len do
    (match s.[!i] with
    | '%' when !i + 2 < len ->
      let hi = s.[!i + 1] in
      let lo = s.[!i + 2] in
      let is_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') in
      if is_hex hi && is_hex lo then begin
        let n = int_of_string (Printf.sprintf "0x%c%c" hi lo) in
        Buffer.add_char buf (Char.chr n);
        i := !i + 3
      end else begin
        Buffer.add_char buf '%';
        incr i
      end
    | c -> Buffer.add_char buf c; incr i);
  done;
  Buffer.contents buf

let split_path path =
  String.split_on_char '/' path |> List.filter (fun s -> s <> "")

let trailing_slash s = s <> "" && s.[String.length s - 1] = '/'

(* Validate and parse a request path.
   Returns None if the path is malformed (consecutive slashes).
   Returns Some (segments, has_trailing_slash) for valid paths. *)
let parse_request_path path =
  let len = String.length path in
  let rec has_double_slash i =
    if i >= len - 1 then false
    else if path.[i] = '/' && path.[i + 1] = '/' then true
    else has_double_slash (i + 1)
  in
  if has_double_slash 0 then None
  else Some (split_path path, trailing_slash path)

(* Match a URL pattern against a request path.
   Pattern segments starting with ':' are named parameters.
   Returns None for path format errors (double slashes), trailing-slash
   mismatches, segment count mismatches, or literal segment mismatches.
   Returns Some params on a full match; params are percent-decoded. *)
let match_path pattern request_path =
  match parse_request_path request_path with
  | None -> None
  | Some (req_segs, req_ts) ->
    if trailing_slash pattern <> req_ts then None
    else
      let rec go pats reqs acc =
        match pats, reqs with
        | [], []       -> Some (List.rev acc)
        | p :: ps, r :: rs ->
          if String.length p > 0 && p.[0] = ':' then
            let key = String.sub p 1 (String.length p - 1) in
            go ps rs ((key, percent_decode r) :: acc)
          else if p = r then go ps rs acc
          else None
        | _ -> None
      in
      go (split_path pattern) req_segs []

(* Map Http.Method.t to our internal variant; None for unknown methods. *)
let method_of_http : Http.Method.t -> Request.method_ option = function
  | `GET    -> Some `GET
  | `POST   -> Some `POST
  | `PUT    -> Some `PUT
  | `PATCH  -> Some `PATCH
  | `DELETE -> Some `DELETE
  | _       -> None
