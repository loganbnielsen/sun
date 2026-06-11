type rollout_strategy = Recreate | RollingUpdate

(** A single step in an Argo Rollouts canary strategy.
    [Weight n]  sets the traffic weight percentage to [n].
    [Pause None] pauses indefinitely (requires manual promotion).
    [Pause (Some s)] pauses for [s] seconds then auto-promotes. *)
type canary_step =
  | Weight of int
  | Pause  of int option

(** Progressive delivery strategy for Argo Rollouts.
    [Canary]     uses weighted traffic-shifting steps.
    [Blue_green] uses two Services (active + preview) with manual promotion. *)
type progressive_delivery =
  | Canary     of { steps : canary_step list }
  | Blue_green

type t = {
  replicas             : int option;
  cpu                  : string option;
  memory               : string option;
  env_config           : (string * string) list;
  secret_keys          : string list;
  rollout_strategy     : rollout_strategy option;
  ingress_host         : string option;
  ingress_path         : string option;
  extra_labels         : (string * string) list;
  progressive_delivery : progressive_delivery option;
}

val empty : t

(** Load and parse a sun.toml file. Returns [empty] if the file does not exist.
    Raises [Failure] with a descriptive message on validation errors:
    - Unknown rollout_strategy values (only "Recreate" and "RollingUpdate" accepted).
    - extra_labels keys starting with "sun.dev/" (reserved namespace).
    - Unknown [infra.rollout] strategy values (only "canary" and "blue-green" accepted).
    - Canary strategy with an empty steps list or weights outside 0..100. *)
val load : string -> t
