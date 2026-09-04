type target = {
  name                   : string;
  env                    : string;
  provider               : string;
  region                 : string;
  registry               : string option;
  base_domain            : string option;
  cluster_name           : string option;
  terraform_var_file     : string option;
  observability_backend  : string option;
}

type resource = {
  name          : string;
  typ           : string option;
  partition_key : string option;
  sort_key      : string option;
  indexes       : string list;
  size          : string option;
  omit          : bool;
}

type service = {
  name      : string;
  typ       : string option;
  path      : string option;
  uses      : string list;
  scale_min : int option;
  scale_max : int option;
  omit      : bool;
}

type t = {
  project   : string option;
  target    : target option;
  resources : resource list;
  services  : service list;
}

type error = { path : string; line : int; message : string }

val error_to_string : error -> string
val load_for_target : target:string -> (t, error) result
val target : t -> target option
val resources : t -> resource list
val services : t -> service list
val terraform_vars : t -> (string list, string) result
