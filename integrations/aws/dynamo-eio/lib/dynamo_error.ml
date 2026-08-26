type t =
  | Aws of Aws_error.t
  | Resource_not_found
  | Conditional_check_failed
  | Service_error of { exn_type : string; message : string }
  | Unparseable_error_response of { status : int; body : string }
  | Malformed_response of string
  | Wrong_entity of { expected : string; got : string option }
  | Invalid_config of string

(* "__type" is namespaced, e.g. "com.amazonaws.dynamodb.v20120810#ResourceNotFoundException"
   — the part after '#' is the actual exception name. *)
let exception_name full_type =
  match String.index_opt full_type '#' with
  | Some i -> String.sub full_type (i + 1) (String.length full_type - i - 1)
  | None -> full_type

(* Avoids Yojson.Safe.Util's member/to_string_option: those raise Type_error
   on anything that isn't the exact shape expected (a bare JSON array or
   string, not an object) — Yojson.Safe.from_string succeeding only proves
   body is *some* valid JSON. Plain List.assoc_opt pattern matching below
   never raises, keeping this a pure, always-Result classifier. *)
let of_response ~status ~body =
  match Yojson.Safe.from_string body with
  | exception _ -> Unparseable_error_response { status; body }
  | `Assoc fields -> (
    match List.assoc_opt "__type" fields with
    | Some (`String full_type) ->
      let message =
        match List.assoc_opt "message" fields with
        | Some (`String m) -> m
        | _ -> ( match List.assoc_opt "Message" fields with Some (`String m) -> m | _ -> "")
      in
      (match exception_name full_type with
       | "ResourceNotFoundException" -> Resource_not_found
       | "ConditionalCheckFailedException" -> Conditional_check_failed
       | exn_type -> Service_error { exn_type; message })
    | _ -> Unparseable_error_response { status; body })
  | _ -> Unparseable_error_response { status; body }

let to_string = function
  | Aws e -> Aws_error.to_string e
  | Resource_not_found -> "resource not found"
  | Conditional_check_failed -> "conditional check failed"
  | Service_error { exn_type; message } -> Printf.sprintf "DynamoDB error %s: %s" exn_type message
  | Unparseable_error_response { status; body } ->
    Printf.sprintf "DynamoDB error %d, unparseable response: %s" status body
  | Malformed_response msg -> "malformed DynamoDB response: " ^ msg
  | Wrong_entity { expected; got } ->
    Printf.sprintf "wrong entity: expected %S, got %s" expected
      (match got with Some g -> Printf.sprintf "%S" g | None -> "no discriminator attribute")
  | Invalid_config msg -> "invalid dynamo-eio config: " ^ msg
