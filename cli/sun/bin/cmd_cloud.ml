open Cmdliner

let cmd =
  Cmd.group
    (Cmd.info "cloud"
       ~doc:"Manage cloud infrastructure and hosted deployments")
    [ Cmd_cloud_tf.init_cmd
    ; Cmd_cloud_deploy.deploy_cmd
    ; Cmd_cloud_releases.releases_cmd
    ; Cmd_cloud_releases.logs_cmd
    ]
