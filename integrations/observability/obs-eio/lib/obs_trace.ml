type t = {
  trace_id    : int64 * int64;
  span_id     : int64;
  trace_flags : char;
  baggage     : (string * string) list;
}

(* Self-seeded so trace/span IDs don't collide across process restarts —
   unlike the global Random module, this needs no Random.self_init () call
   from the caller (easy to forget, and silently falls back to a fixed seed). *)
let rng_state = Random.State.make_self_init ()
let random_int64 () = Random.State.int64 rng_state Int64.max_int

let generate () = {
  trace_id    = (random_int64 (), random_int64 ());
  span_id     = random_int64 ();
  trace_flags = '\x01';  (* sampled *)
  baggage     = [];
}

let child_span t = { t with span_id = random_int64 () }

let traceparent_header = "traceparent"

let header_name_equal a b =
  String.equal (String.lowercase_ascii a) (String.lowercase_ascii b)

let assoc_header_opt name headers =
  List.find_map
    (fun (k, v) -> if header_name_equal k name then Some v else None)
    headers

let to_traceparent t =
  let (hi, lo) = t.trace_id in
  Printf.sprintf "00-%016Lx%016Lx-%016Lx-%02x"
    hi lo t.span_id (Char.code t.trace_flags)

let of_traceparent s =
  match String.split_on_char '-' s with
  | [version; trace_hex; span_hex; flags_hex]
    when version = "00"
      && String.length trace_hex = 32
      && String.length span_hex  = 16
      && String.length flags_hex = 2 ->
    (try
       let hi = Int64.of_string ("0x" ^ String.sub trace_hex  0 16) in
       let lo = Int64.of_string ("0x" ^ String.sub trace_hex 16 16) in
       let si = Int64.of_string ("0x" ^ span_hex) in
       let fl = Char.chr (int_of_string ("0x" ^ flags_hex)) in
       Some { trace_id = (hi, lo); span_id = si; trace_flags = fl; baggage = [] }
     with _ -> None)
  | _ -> None

let extract_from_headers headers =
  match assoc_header_opt traceparent_header headers with
  | None   -> None
  | Some v -> of_traceparent v

let inject_to_headers ctx headers =
  let tp      = to_traceparent ctx in
  let without =
    List.filter (fun (k, _) -> not (header_name_equal k traceparent_header)) headers
  in
  (traceparent_header, tp) :: without
