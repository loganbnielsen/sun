module Type    = Caqti_type
module Request = Caqti_request

(* Polymorphic record field hides the caqti pool's type variable. *)
type pool = {
  use_conn :
    'b. (Caqti_eio.connection -> ('b, Storage_error.t) result) ->
        ('b, Storage_error.t) result;
}

(* Internal — carries application errors out of Pool.use callbacks. *)
exception App_error of Storage_error.t

let translate_error e =
  Storage_error.Query_error (Caqti_error.show e)

let create_pool ~url ?pool_size ~sw ~stdenv () =
  let uri = Uri.of_string url in
  let pool_config = match pool_size with
    | None   -> Caqti_pool_config.create ()
    | Some n -> Caqti_pool_config.create ~max_size:n ()
  in
  match Caqti_eio_unix.connect_pool ~sw ~stdenv ~pool_config uri with
  | Error e -> Error (Storage_error.Connection_failed (Caqti_error.show e))
  | Ok p    ->
    let use_conn (type b)
        (f : Caqti_eio.connection -> (b, Storage_error.t) result)
        : (b, Storage_error.t) result =
      try
        match Caqti_eio.Pool.use (fun conn ->
          match f conn with
          | Ok v    -> Ok v
          | Error e -> raise (App_error e)
        ) p with
        | Ok v    -> Ok v
        | Error e -> Error (Storage_error.Connection_failed (Caqti_error.show e))
      with App_error e -> Error e
    in
    Ok { use_conn }

let exec pool req params =
  pool.use_conn (fun (module C : Caqti_eio.CONNECTION) ->
    match C.exec req params with
    | Ok ()   -> Ok ()
    | Error e -> Error (translate_error e))

let find pool req params =
  pool.use_conn (fun (module C : Caqti_eio.CONNECTION) ->
    match C.find_opt req params with
    | Ok r    -> Ok r
    | Error e -> Error (translate_error e))

let collect pool req params =
  pool.use_conn (fun (module C : Caqti_eio.CONNECTION) ->
    match C.collect_list req params with
    | Ok r    -> Ok r
    | Error e -> Error (translate_error e))

let transaction pool f =
  pool.use_conn (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    match C.start () with
    | Error e -> Error (translate_error e)
    | Ok () ->
      let tx_pool = { use_conn = fun g -> g conn } in
      let result = f tx_pool in
      match result with
      | Ok _ ->
        (match C.commit () with
         | Error e -> Error (translate_error e)
         | Ok ()   -> result)
      | Error _ ->
        ignore (C.rollback ());
        result)
