type t =
  | S of string
  | N of string
  | B of string
  | Bool of bool
  | Null
  | Ss of string list
  | Ns of string list
  | Bs of string list
  | L of t list
  | M of (string * t) list

let ( let* ) = Result.bind

let rec to_json = function
  | S s -> `Assoc [ ("S", `String s) ]
  | N n -> `Assoc [ ("N", `String n) ]
  | B b -> `Assoc [ ("B", `String (Base64.encode_string b)) ]
  | Bool b -> `Assoc [ ("BOOL", `Bool b) ]
  | Null -> `Assoc [ ("NULL", `Bool true) ]
  | Ss l -> `Assoc [ ("SS", `List (List.map (fun s -> `String s) l)) ]
  | Ns l -> `Assoc [ ("NS", `List (List.map (fun s -> `String s) l)) ]
  | Bs l -> `Assoc [ ("BS", `List (List.map (fun b -> `String (Base64.encode_string b)) l)) ]
  | L l -> `Assoc [ ("L", `List (List.map to_json l)) ]
  | M m -> `Assoc [ ("M", `Assoc (List.map (fun (k, v) -> (k, to_json v)) m)) ]

let string_list_of_json = function
  | `List items ->
    List.fold_left
      (fun acc item ->
        let* acc = acc in
        match item with `String s -> Ok (s :: acc) | _ -> Error "expected a JSON string in a string-list attribute")
      (Ok []) items
    |> Result.map List.rev
  | _ -> Error "expected a JSON array for an SS/NS/BS attribute"

let decode_base64_list strings =
  List.fold_left
    (fun acc s ->
      let* acc = acc in
      match Base64.decode s with Ok b -> Ok (b :: acc) | Error (`Msg m) -> Error ("invalid base64 in BS: " ^ m))
    (Ok []) strings
  |> Result.map List.rev

let rec of_json = function
  | `Assoc [ ("S", `String s) ] -> Ok (S s)
  | `Assoc [ ("N", `String n) ] -> Ok (N n)
  | `Assoc [ ("B", `String b) ] -> (
    match Base64.decode b with Ok raw -> Ok (B raw) | Error (`Msg m) -> Error ("invalid base64 in B: " ^ m))
  | `Assoc [ ("BOOL", `Bool b) ] -> Ok (Bool b)
  | `Assoc [ ("NULL", `Bool true) ] -> Ok Null
  | `Assoc [ ("SS", list) ] -> Result.map (fun l -> Ss l) (string_list_of_json list)
  | `Assoc [ ("NS", list) ] -> Result.map (fun l -> Ns l) (string_list_of_json list)
  | `Assoc [ ("BS", list) ] ->
    let* strings = string_list_of_json list in
    Result.map (fun l -> Bs l) (decode_base64_list strings)
  | `Assoc [ ("L", `List items) ] ->
    List.fold_left
      (fun acc item ->
        let* acc = acc in
        let* v = of_json item in
        Ok (v :: acc))
      (Ok []) items
    |> Result.map (fun l -> L (List.rev l))
  | `Assoc [ ("M", `Assoc fields) ] ->
    List.fold_left
      (fun acc (k, v) ->
        let* acc = acc in
        let* v = of_json v in
        Ok ((k, v) :: acc))
      (Ok []) fields
    |> Result.map (fun l -> M (List.rev l))
  | json -> Error ("not a recognized DynamoDB attribute-value shape: " ^ Yojson.Safe.to_string json)
