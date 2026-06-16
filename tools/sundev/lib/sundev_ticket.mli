val ticket_states : string list

val parse_frontmatter : string -> (string * string) list
val fm_get : (string * string) list -> string -> string option

val parse_depends : string -> string list
val has_human_decision_gate : string -> bool
val human_decision_details : string -> string
val ticket_title : string -> string

val find_ticket : string -> (string * string) option
val dependency_status : string -> [ `Done | `Unknown | `Blocked of string ]
val dependency_summary : string list -> string
val readiness_label : string -> string -> string
