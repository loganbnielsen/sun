type t =
  | Aws of Aws_error.t
  | Not_found
  | Service_error of { code : string; message : string; status : int }
  | Unparseable_error_response of { status : int; body : string }
  | Invalid_config of string

let of_response ~status ~body =
  if status = 404 then Not_found
  else
    match (Aws_credentials.extract_tag "Code" body, Aws_credentials.extract_tag "Message" body) with
    | Some code, Some message -> Service_error { code; message; status }
    | _ -> Unparseable_error_response { status; body }

let to_string = function
  | Aws e -> Aws_error.to_string e
  | Not_found -> "not found"
  | Service_error { code; message; status } -> Printf.sprintf "S3 error %d (%s): %s" status code message
  | Unparseable_error_response { status; body } ->
    Printf.sprintf "S3 error %d, unparseable response: %s" status body
  | Invalid_config msg -> "invalid s3-eio config: " ^ msg
