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

let ( let* ) = Result.bind

let translate_error e =
  Storage_error.Query_error (Caqti_error.show e)

let map_err r = Result.map_error translate_error r

let create_pool ~url ?pool_size ~sw ~stdenv () =
  let uri = Uri.of_string url in
  let pool_config = match pool_size with
    | None   -> Caqti_pool_config.create ()
    | Some n -> Caqti_pool_config.create ~max_size:n ()
  in
  let* p = Caqti_eio_unix.connect_pool ~sw ~stdenv ~pool_config uri
    |> Result.map_error (fun e -> Storage_error.Connection_failed (Caqti_error.show e)) in
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
    map_err (C.exec req params))

let find pool req params =
  pool.use_conn (fun (module C : Caqti_eio.CONNECTION) ->
    map_err (C.find_opt req params))

let collect pool req params =
  pool.use_conn (fun (module C : Caqti_eio.CONNECTION) ->
    map_err (C.collect_list req params))

let transaction pool f =
  pool.use_conn (fun conn ->
    let module C = (val conn : Caqti_eio.CONNECTION) in
    let* () = map_err (C.start ()) in
    let tx_pool = { use_conn = fun g -> g conn } in
    let result = f tx_pool in
    match result with
    | Ok _ ->
      let* () = map_err (C.commit ()) in
      result
    | Error _ ->
      ignore (C.rollback ());
      result)
