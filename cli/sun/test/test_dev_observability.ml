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
  assert_contains "service uid" yaml "\"uid\": \"sun-service-template\""

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

let () =
  Alcotest.run "dev_observability"
    [ "grafana",
      [ Alcotest.test_case "dashboard configmap" `Quick test_dashboard_configmap;
        Alcotest.test_case "prometheus datasource configmap" `Quick
          test_prometheus_datasource_configmap;
      ];
    ]
