(** Reads shared platform-component desired state from
    [platform/components/<component>/] (ADR 0001 / CODE_LAYER-005) so
    [sun dev up] and [platform/infra/base/main.tf]'s [helm_release] resources
    stop hand-duplicating the same Helm values. *)

(** [merged_values_yaml ~component ~profile] reads
    [platform/components/<component>/values-common.json] and
    [values-<profile>.json], deep-merges the profile file over common
    (profile wins on key conflicts; nested objects merge recursively, other
    conflicts take the profile's value outright), and returns the merged
    document as JSON text. JSON is valid YAML, so this is suitable as-is for
    {!Sun_cli_helm.upgrade_install}'s [?values_yaml].

    A missing file (a component with nothing to say for that layer, e.g.
    [tempo]'s empty profiles) is treated as an empty object, not an error.
    Exits with an error message if the Sun monorepo root can't be located
    (same resolution as [sun cloud plan/apply], see
    {!Sun_cli_cmd_new.infer_sun_home}). *)
val merged_values_yaml : component:string -> profile:string -> string
