module type SCHEMA = sig
  val table     : string
  val id_column : string
  val columns   : string list
  (** All column names in order, matching the fields of [row_type]. *)

  type t
  type id

  val row_type : t Caqti_type.t
  (** Encodes/decodes the full row. Field order must match [columns]. *)

  val id_type  : id Caqti_type.t
  val get_id   : t -> id
end

module Limit : sig
  type t = private int

  val max_value : int
  val of_int : int -> (t, Storage_error.t) result
  val to_int : t -> int
end = struct
  type t = int

  let max_value = 10_000

  let of_int n =
    if n <= 0 then
      Error (Storage_error.Query_error "table list limit must be positive")
    else if n > max_value then
      Error
        (Storage_error.Query_error
           (Printf.sprintf "table list limit must be <= %d" max_value))
    else
      Ok n

  let to_int n = n
end

module Offset : sig
  type t = private int

  val of_int : int -> (t, Storage_error.t) result
  val to_int : t -> int
end = struct
  type t = int

  let of_int n =
    if n < 0 then
      Error (Storage_error.Query_error "table list offset must be non-negative")
    else
      Ok n

  let to_int n = n
end

module Make (S : SCHEMA) = struct

  let placeholders n =
    List.init n (fun _ -> "?") |> String.concat ", "

  let col_list = String.concat ", " S.columns

  let find_q =
    Caqti_request.Infix.(S.id_type ->? S.row_type)
      (Printf.sprintf "SELECT %s FROM %s WHERE %s = ?" col_list S.table S.id_column)

  let insert_q =
    Caqti_request.Infix.(S.row_type ->. Caqti_type.unit)
      (Printf.sprintf "INSERT INTO %s (%s) VALUES (%s)"
         S.table col_list (placeholders (List.length S.columns)))

  let delete_q =
    Caqti_request.Infix.(S.id_type ->. Caqti_type.unit)
      (Printf.sprintf "DELETE FROM %s WHERE %s = ?" S.table S.id_column)

  let list_q =
    Caqti_request.Infix.(Caqti_type.(t2 int int) ->* S.row_type)
      (Printf.sprintf "SELECT %s FROM %s LIMIT ? OFFSET ?" col_list S.table)

  let find   pool id  = Db.find    pool find_q   id
  let insert pool row = Db.exec    pool insert_q  row
  let delete pool id  = Db.exec    pool delete_q  id

  let list pool ?(limit = 100) ?(offset = 0) () =
    match Limit.of_int limit, Offset.of_int offset with
    | Ok limit, Ok offset ->
      Db.collect pool list_q (Limit.to_int limit, Offset.to_int offset)
    | Error e, _ | _, Error e ->
      Error e
end
