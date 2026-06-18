type k8s_name
type namespace

val make_k8s_name : string -> (k8s_name, string) result
(** Validate an already-normalized Kubernetes object name. *)

val make_namespace : string -> (namespace, string) result
(** Validate an already-normalized Kubernetes namespace. *)

val k8s_name_of_source : string -> (k8s_name, string) result
(** Normalize a service source name, then validate it as a DNS label. *)

val namespace_of_parts : workspace:string -> domain:string -> (namespace, string) result
(** Normalize workspace/domain parts, join them with ["-"], then validate. *)

val normalize : string -> string
(** Lowercase ASCII and map underscores to hyphens. *)

val k8s_name_to_string : k8s_name -> string
val namespace_to_string : namespace -> string
