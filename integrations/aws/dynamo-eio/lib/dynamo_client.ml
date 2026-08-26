type config = {
  table : string;
  region : string;
  credentials : Aws_credentials.t;
}

type item = (string * Dynamo_value.t) list

let ( let* ) = Result.bind

let item_to_json (item : item) : Yojson.Safe.t =
  `Assoc (List.map (fun (k, v) -> (k, Dynamo_value.to_json v)) item)

let item_of_json = function
  | `Assoc fields ->
    List.fold_left
      (fun acc (k, v) ->
        let* acc = acc in
        let* v = Dynamo_value.of_json v in
        Ok ((k, v) :: acc))
      (Ok []) fields
    |> Result.map List.rev
  | json -> Error ("expected a JSON object for a DynamoDB item, got: " ^ Yojson.Safe.to_string json)

let build_request_body fields = Yojson.Safe.to_string (`Assoc fields)

let resolve_credentials ~net ~clock config =
  match Aws_credentials.resolve ~net ~clock config.credentials with
  | Error e -> Error (Dynamo_error.Aws e)
  | Ok creds -> Ok creds

let has_crlf s = String.exists (fun c -> c = '\r' || c = '\n') s

(* config.region is spliced unvalidated into the Host header/connection
   target (Printf.sprintf "dynamodb.%s.amazonaws.com" config.region) — the
   same CRLF-header-injection class of bug already found and fixed in
   s3-eio's validate_config, not originally carried over here. table isn't
   part of this check: it only ever appears inside the JSON request body
   (the "TableName" field), safely encoded by Yojson, never spliced into a
   header line. *)
let validate_config config =
  if has_crlf config.region then Error (Dynamo_error.Invalid_config "region contains a CR or LF character")
  else Ok ()

(* aws-eio's signed_request already converts every non-2xx status into
   Error (Http_error (status, body)) before returning — the same dead-code
   finding as s3-eio's (interpret_*'s non-2xx branches were unreachable
   through the real call path). Factored out as its own pure, testable
   function for the same reason: this package's tests can't exercise the
   real network/TLS path locally either. *)
let reclassify_transport_result :
    (int * (string * string) list * string, Aws_error.t) result ->
    (int * (string * string) list * string, Dynamo_error.t) result = function
  | Error (Aws_error.Http_error (status, body)) -> Ok (status, [], body)
  | Error e -> Error (Dynamo_error.Aws e)
  | Ok (status, headers, body) -> Ok (status, headers, body)

(* Every operation resolves credentials fresh, same rationale (and the same
   deferred-caching gap) as s3-eio's Dynamo_client-equivalent — see
   dynamo-eio.md's "Out of Scope". *)
let call ~net ~clock config ~action ~body () =
  let* () = validate_config config in
  let* creds = resolve_credentials ~net ~clock config in
  let host = Printf.sprintf "dynamodb.%s.amazonaws.com" config.region in
  let extra_headers =
    [ ("Content-Type", "application/x-amz-json-1.0");
      ("X-Amz-Target", "DynamoDB_20120810." ^ action);
    ]
  in
  reclassify_transport_result
    (Aws_http.signed_request ~net ~clock
       ~access_key_id:creds.access_key_id
       ~secret_access_key:creds.secret_access_key
       ?session_token:creds.session_token
       ~region:config.region ~service:"dynamodb" ~normalize_path:true
       ~meth:`POST ~host ~path:"/" ~extra_headers ~body ())

(* Response interpretation is pure and separated from call for the same
   reason as s3-eio's interpret_* functions: unit-testable with synthetic
   (status, headers, body) triples, no network/TLS involved. *)
let interpret_put (status, _headers, body) =
  if status >= 200 && status < 300 then Ok () else Error (Dynamo_error.of_response ~status ~body)

let interpret_get (status, _headers, body) =
  if status < 200 || status >= 300 then Error (Dynamo_error.of_response ~status ~body)
  else
    match Yojson.Safe.from_string body with
    | exception _ -> Error (Dynamo_error.Malformed_response ("GetItem response is not valid JSON: " ^ body))
    | `Assoc fields -> (
      match List.assoc_opt "Item" fields with
      | None -> Ok None
      | Some item_json -> (
        match item_of_json item_json with
        | Ok item -> Ok (Some item)
        | Error msg -> Error (Dynamo_error.Malformed_response msg)))
    | json -> Error (Dynamo_error.Malformed_response ("expected a JSON object, got: " ^ Yojson.Safe.to_string json))

let interpret_delete (status, _headers, body) =
  if status >= 200 && status < 300 then Ok () else Error (Dynamo_error.of_response ~status ~body)

let interpret_query (status, _headers, body) =
  if status < 200 || status >= 300 then Error (Dynamo_error.of_response ~status ~body)
  else
    match Yojson.Safe.from_string body with
    | exception _ -> Error (Dynamo_error.Malformed_response ("Query response is not valid JSON: " ^ body))
    | `Assoc fields -> (
      match List.assoc_opt "Items" fields with
      | None -> Error (Dynamo_error.Malformed_response "Query response has no \"Items\" field")
      | Some (`List items) -> (
        List.fold_left
          (fun acc item_json ->
            let* acc = acc in
            match item_of_json item_json with Ok item -> Ok (item :: acc) | Error msg -> Error msg)
          (Ok []) items
        |> function
        | Ok items -> Ok (List.rev items)
        | Error msg -> Error (Dynamo_error.Malformed_response msg))
      | Some json ->
        Error (Dynamo_error.Malformed_response ("\"Items\" is not a JSON array: " ^ Yojson.Safe.to_string json)))
    | json -> Error (Dynamo_error.Malformed_response ("expected a JSON object, got: " ^ Yojson.Safe.to_string json))

let put_item ~net ~clock config ~item =
  let body = build_request_body [ ("TableName", `String config.table); ("Item", item_to_json item) ] in
  match call ~net ~clock config ~action:"PutItem" ~body () with
  | Error _ as e -> e
  | Ok r -> interpret_put r

let get_item ~net ~clock config ~key =
  let body = build_request_body [ ("TableName", `String config.table); ("Key", item_to_json key) ] in
  match call ~net ~clock config ~action:"GetItem" ~body () with
  | Error _ as e -> e
  | Ok r -> interpret_get r

let delete_item ~net ~clock config ~key =
  let body = build_request_body [ ("TableName", `String config.table); ("Key", item_to_json key) ] in
  match call ~net ~clock config ~action:"DeleteItem" ~body () with
  | Error _ as e -> e
  | Ok r -> interpret_delete r

let query ~net ~clock config ?index_name ?expression_attribute_names ~key_condition_expression
    ~expression_attribute_values () =
  let fields =
    [ ("TableName", `String config.table);
      ("KeyConditionExpression", `String key_condition_expression);
      ("ExpressionAttributeValues", item_to_json expression_attribute_values);
    ]
    @ (match index_name with Some n -> [ ("IndexName", `String n) ] | None -> [])
    @
    match expression_attribute_names with
    | Some names when names <> [] ->
      [ ("ExpressionAttributeNames", `Assoc (List.map (fun (k, v) -> (k, `String v)) names)) ]
    | _ -> []
  in
  let body = build_request_body fields in
  match call ~net ~clock config ~action:"Query" ~body () with
  | Error _ as e -> e
  | Ok r -> interpret_query r
