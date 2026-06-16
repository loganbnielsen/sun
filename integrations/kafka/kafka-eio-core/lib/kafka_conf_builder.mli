val make : unit ->
  Kafka_raw.kafka_conf *
  (string -> string -> unit) *
  (string -> unit) *
  (unit -> (Kafka_raw.kafka_conf, string) result)
