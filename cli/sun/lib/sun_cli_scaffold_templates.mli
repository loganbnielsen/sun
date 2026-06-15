(** Template strings for [sun new] scaffold commands.

    All values are literal file contents or {{key}} substitution templates
    consumed by [Sun_cli_scaffold.subst]. *)

val tpl_ocamlformat      : string
val tpl_dune_project     : string
val tpl_readme           : string
val tpl_sun_toml         : string
val tpl_github_ci        : string
val tpl_github_deploy    : string
val tpl_dockerfile       : string
val tpl_dockerignore     : string

val ws_charged_ml        : string
val ws_events_dune       : string
val ws_notification_ml   : string
val ws_storage_dune      : string
val ws_svc_handler_ml    : string
val ws_svc_lib_dune      : string
val ws_svc_bin_ml        : string
val ws_svc_bin_dune      : string
val ws_worker_ml         : string
val ws_worker_lib_dune   : string
val ws_worker_bin_ml     : string
val ws_worker_bin_dune   : string
val ws_migration_sql     : string
val ws_migration_down_sql: string
val ws_test_schemas_ml   : string
val ws_test_dune         : string

val svc_handler_ml       : string
val svc_lib_dune         : string
val svc_bin_ml           : string
val svc_bin_dune         : string
val worker_lib_ml        : string
val worker_lib_dune      : string
val worker_bin_ml        : string
val worker_bin_dune      : string
val fn_lib_ml            : string
val fn_lib_dune          : string
val fn_bin_ml            : string
val fn_bin_dune          : string

val event_ml             : string
