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

(* ── Internal path matching (used by Service) ─────────────────────────── *)

let split_path path =
  String.split_on_char '/' path |> List.filter (fun s -> s <> "")

let trailing_slash s = s <> "" && s.[String.length s - 1] = '/'

let match_path pattern request_path =
  if trailing_slash pattern <> trailing_slash request_path then None
  else
    let rec go pats reqs acc =
      match pats, reqs with
      | [], []       -> Some (List.rev acc)
      | p :: ps, r :: rs ->
        if String.length p > 0 && p.[0] = ':' then
          go ps rs ((String.sub p 1 (String.length p - 1), r) :: acc)
        else if p = r then
          go ps rs acc
        else
          None
      | _ -> None
    in
    go (split_path pattern) (split_path request_path) []

(* Map Http.Method.t to our internal variant; None for unknown methods. *)
let method_of_http : Http.Method.t -> Request.method_ option = function
  | `GET    -> Some `GET
  | `POST   -> Some `POST
  | `PUT    -> Some `PUT
  | `PATCH  -> Some `PATCH
  | `DELETE -> Some `DELETE
  | _       -> None
