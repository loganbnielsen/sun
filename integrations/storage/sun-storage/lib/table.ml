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
    Db.collect pool list_q (limit, offset)
end
