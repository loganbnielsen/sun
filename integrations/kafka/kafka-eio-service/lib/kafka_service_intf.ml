module type MESSAGE = sig
  type t
  val topic_name : string
  val schema : string
  val encode : t -> Yojson.Safe.t
  val decode : Yojson.Safe.t -> (t, string) result
end
