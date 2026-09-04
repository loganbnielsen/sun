let check_bool = Alcotest.(check bool)

let contains needle haystack =
  try ignore (Str.search_forward (Str.regexp_string needle) haystack 0); true
  with Not_found -> false

let assert_contains msg s needle =
  check_bool msg true (contains needle s)

let test_dashboard_configmap () =
  let yaml = Sun_cli_dev_observability.dashboard_configmap_yaml ~namespace:"monitoring" in
  assert_contains "kind" yaml "kind: ConfigMap";
  assert_contains "name" yaml "name: sun-grafana-dashboards";
  assert_contains "namespace" yaml "namespace: monitoring";
  assert_contains "sidecar label" yaml "grafana_dashboard: \"1\"";
  assert_contains "workspace uid" yaml "\"uid\": \"sun-workspace-overview\"";
  assert_contains "domain uid" yaml "\"uid\": \"sun-domain-overview\"";
  assert_contains "service uid" yaml "\"uid\": \"sun-service-template\"";
  assert_contains "release timeline uid" yaml "\"uid\": \"sun-release-timeline\"";
  assert_contains "release timeline query" yaml
    "{workspace=\\\"$workspace\\\", domain=\\\"$domain\\\", service=\\\"$service\\\"} | logfmt | event=\\\"deploy\\\""

let test_prometheus_datasource_configmap () =
  let yaml =
    Sun_cli_dev_observability.prometheus_datasource_configmap_yaml
      ~namespace:"monitoring"
  in
  assert_contains "name" yaml "name: grafana-prometheus-datasource";
  assert_contains "sidecar label" yaml "grafana_datasource: \"1\"";
  assert_contains "datasource" yaml "name: Prometheus";
  assert_contains "url" yaml
    "url: http://prometheus-server.monitoring.svc.cluster.local:80"

(* OBS-039: no longer auto-provisioned by a bundled loki-stack Grafana
   subchart -- see sun_cli_dev_observability.ml's comment on
   loki_datasource_configmap_yaml. Every dashboard above references a
   datasource named exactly "Loki", so a missing/misnamed datasource here
   silently breaks every Loki panel.
   OBS-042: also asserts the derivedFields link to Tempo -- a trace_id in a
   Loki log line must be clickable through to its Tempo waterfall. *)
let test_loki_datasource_configmap () =
  let yaml =
    Sun_cli_dev_observability.loki_datasource_configmap_yaml
      ~namespace:"monitoring"
  in
  assert_contains "name" yaml "name: grafana-loki-datasource";
  assert_contains "sidecar label" yaml "grafana_datasource: \"1\"";
  assert_contains "datasource" yaml "name: Loki";
  assert_contains "url" yaml "url: http://loki:3100";
  assert_contains "derivedFields datasourceUid" yaml "datasourceUid: tempo";
  assert_contains "derivedFields matcherRegex" yaml "matcherRegex: \"trace_id=(\\w+)\"";
  assert_contains "derivedFields name" yaml "name: TraceID";
  assert_contains "derivedFields url" yaml "url: \"${__value.raw}\""

(* OBS-042: Tempo query API (port 3200, distinct from the OTLP/HTTP
   ingestion port 4318 obs-tempo-eio's -svc backend pushes spans to)
   exposed as a Grafana datasource, mirroring Loki/Prometheus above. uid is
   pinned so the Loki datasource's derivedFields entry above can reference
   it by a stable value. *)
let test_tempo_datasource_configmap () =
  let yaml =
    Sun_cli_dev_observability.tempo_datasource_configmap_yaml
      ~namespace:"monitoring"
  in
  assert_contains "name" yaml "name: grafana-tempo-datasource";
  assert_contains "sidecar label" yaml "grafana_datasource: \"1\"";
  assert_contains "datasource" yaml "name: Tempo";
  assert_contains "uid" yaml "uid: tempo";
  assert_contains "url" yaml "url: http://tempo:3200"

(* OBS-039: Alloy replaces promtail as the log shipper. This is real Alloy
   River config, not Promtail-shaped YAML -- assert on the actual
   component/attribute names (discovery.kubernetes, loki.source.kubernetes,
   loki.write) and the taxonomy relabeling
   (Sun_cli_manifest_yaml's render_taxonomy_labels) rather than anything
   promtail-specific. *)
let test_alloy_values_yaml () =
  let yaml = Sun_cli_dev_observability.alloy_values_yaml in
  assert_contains "helm values shape" yaml "configMap:";
  assert_contains "content block" yaml "content: |-";
  assert_contains "pod discovery" yaml "discovery.kubernetes \"pods\"";
  assert_contains "kubernetes API tailing" yaml "loki.source.kubernetes \"pods\"";
  assert_contains "write component" yaml "loki.write \"default\"";
  assert_contains "push url" yaml "http://loki:3100/loki/api/v1/push";
  assert_contains "taxonomy label: workspace" yaml
    "__meta_kubernetes_pod_label_workspace";
  assert_contains "taxonomy label: domain" yaml
    "__meta_kubernetes_pod_label_domain";
  assert_contains "taxonomy label: service" yaml
    "__meta_kubernetes_pod_label_service";
  assert_contains "taxonomy label: primitive" yaml
    "__meta_kubernetes_pod_label_primitive";
  assert_contains "taxonomy label: release" yaml
    "__meta_kubernetes_pod_label_release"

let () =
  Alcotest.run "dev_observability"
    [ "grafana",
      [ Alcotest.test_case "dashboard configmap" `Quick test_dashboard_configmap;
        Alcotest.test_case "prometheus datasource configmap" `Quick
          test_prometheus_datasource_configmap;
        Alcotest.test_case "loki datasource configmap" `Quick
          test_loki_datasource_configmap;
        Alcotest.test_case "tempo datasource configmap" `Quick
          test_tempo_datasource_configmap;
      ];
      "alloy",
      [ Alcotest.test_case "values yaml" `Quick test_alloy_values_yaml;
      ];
    ]
