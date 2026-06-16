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
            go ps rs ((key, Uri.pct_decode r) :: acc)
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
