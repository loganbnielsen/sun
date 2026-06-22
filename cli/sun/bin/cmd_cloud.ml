open Cmdliner

let cmd =
  Cmd.group
    (Cmd.info "cloud"
       ~doc:"Provision cloud infrastructure")
    [ Cmd_cloud_tf.init_cmd
    ]
