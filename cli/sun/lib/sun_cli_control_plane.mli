(** Hosted control-plane HTTP API surface — stub handlers.

    Defines the request/response contract for the three registry endpoints.
    Handlers are pure functions: they take a registry and a parsed request
    and return a typed response. No TCP server, no I/O.

    Endpoints:
    {ul
    {- [POST /projects]  — create a project for the given workspace}
    {- [GET  /projects/{id}] — fetch project metadata + release IDs}
    {- [POST /projects/{id}/releases] — record a new release}} *)

type http_method = Get | Post

type request = {
  meth : http_method;
  path : string;
  body : Yojson.Safe.t option;
}

type response = {
  status : int;
  body   : Yojson.Safe.t;
}

val handle : Sun_cli_registry.t -> request -> response
(** Dispatch a request to the matching handler.
    Returns 404 for unknown routes and 400 for malformed bodies. *)

(** Convenience constructors used by tests. *)

val post_projects : workspace:string -> request
val get_project   : project_id:string -> request
val post_release  :
  project_id:string ->
  environment:string ->
  image_tag:string ->
  service_names:string list ->
  request
