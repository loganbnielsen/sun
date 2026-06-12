(** In-memory hosted project registry.

    Stub implementation for local end-to-end testing. Provides the data model
    and CRUD operations that a future hosted control plane will persist to a
    database. No I/O, no auth, no persistence — state is lost when the process
    exits.

    The registry is the backbone that [sun cloud deploy] writes into and that
    CLOUD-002/CLOUD-003 build on. *)

type project_id = string
type release_id = string

type release_status =
  | Queued
  | Building
  | Live
  | Failed

type service_status =
  | Service_live
  | Service_failed

type release_service = {
  service_name   : string;
  service_status : service_status;
}

type project = {
  project_id : project_id;
  workspace  : string;
}
(** One project per workspace. Project ID is derived deterministically from the
    workspace name so the same project is found across CLI invocations (within
    one process lifetime). *)

type release = {
  release_id  : release_id;
  project_id  : project_id;
  environment : string;
  image_tag   : string;
  digest      : string option;
  services    : release_service list;
  status      : release_status;
  created_at  : string;
}

type t
(** Registry handle. Create with [create ()]; not thread-safe. *)

val create : unit -> t

val create_project : t -> workspace:string -> (project, string) result
(** Create or return the existing project for [workspace]. Idempotent. *)

val get_project : t -> project_id -> (project, string) result

val list_projects : t -> project list

val create_release :
  t ->
  project_id:project_id ->
  environment:string ->
  image_tag:string ->
  service_names:string list ->
  (release, string) result
(** Record a new release under [project_id]. Fails if the project does not
    exist. The stub always sets [status = Live]. *)

val list_releases : t -> project_id:project_id -> (release list, string) result
(** List releases for [project_id] in creation order. *)

val list_releases_page :
  t ->
  project_id:project_id ->
  ?page:int ->
  ?page_size:int ->
  unit ->
  (release list * int, string) result
(** Paginated release list. [page] is 1-based (default 1). Returns [(items, total)]. *)

val get_release : t -> release_id -> (release, string) result

val append_log_line : t -> release_id -> string -> unit
(** Append a log line to a release's in-memory log buffer. *)

val update_release_digest : t -> release_id -> string -> (unit, string) result
(** Update the digest field on an existing release. Error if not found. *)

val update_release_status : t -> release_id -> string -> (unit, string) result
(** Update the status field on an existing release. Accepts "failed", "building",
    "live", or "queued". Error if not found. *)

val get_release_logs : t -> release_id -> (string list, string) result
(** Return all log lines for a release. Error if the release does not exist. *)

val project_id_of_workspace : string -> project_id
(** Derive the project ID for a workspace name. Exposed for tests. *)

val release_status_to_string : release_status -> string
val service_status_to_string : service_status -> string
val release_service_to_json  : release_service -> Yojson.Safe.t
val project_to_json : project -> Yojson.Safe.t
val release_to_json : release -> Yojson.Safe.t
