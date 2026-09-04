let indent_block s =
  s
  |> String.split_on_char '\n'
  |> List.map (fun line -> "    " ^ line)
  |> String.concat "\n"

let configmap_yaml ~name ~namespace ~labels ~data =
  let labels_yaml =
    labels
    |> List.map (fun (k, v) -> Printf.sprintf "    %s: %S" k v)
    |> String.concat "\n"
  in
  let data_yaml =
    data
    |> List.map (fun (k, v) -> Printf.sprintf "  %s: |-\n%s" k (indent_block v))
    |> String.concat "\n"
  in
  Printf.sprintf
    {|apiVersion: v1
kind: ConfigMap
metadata:
  name: %s
  namespace: %s
  labels:
%s
data:
%s
|} name namespace labels_yaml data_yaml

let prometheus_datasource_yaml ~namespace =
  Printf.sprintf
    {|apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus-server.%s.svc.cluster.local:80
    isDefault: false|} namespace

let workspace_overview_json = {json|{
  "title": "Sun Workspace Overview",
  "uid": "sun-workspace-overview",
  "schemaVersion": 39,
  "version": 1,
  "editable": true,
  "time": { "from": "now-6h", "to": "now" },
  "tags": ["sun"],
  "templating": {
    "list": [
      {
        "name": "workspace",
        "type": "query",
        "datasource": "Loki",
        "query": "label_values(workspace)",
        "refresh": 2,
        "includeAll": false
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "title": "Request rate by domain",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "datasource": "Prometheus",
      "targets": [
        {
          "expr": "sum(rate(sun_svc_requests_total{workspace=\"$workspace\"}[5m])) by (domain)",
          "legendFormat": "{{domain}}"
        }
      ]
    },
    {
      "id": 2,
      "title": "5xx error rate by domain",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "datasource": "Prometheus",
      "targets": [
        {
          "expr": "sum(rate(sun_svc_requests_total{workspace=\"$workspace\", status_class=\"5xx\"}[5m])) by (domain)",
          "legendFormat": "{{domain}}"
        }
      ]
    },
    {
      "id": 3,
      "title": "Scraped targets up, by domain",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "datasource": "Prometheus",
      "targets": [
        {
          "expr": "sum(up{workspace=\"$workspace\"}) by (domain)",
          "legendFormat": "{{domain}}"
        }
      ]
    },
    {
      "id": 4,
      "title": "Recent logs, all domains",
      "type": "logs",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "datasource": "Loki",
      "targets": [
        { "expr": "{workspace=\"$workspace\"}" }
      ]
    }
  ]
}|json}

let domain_overview_json = {json|{
  "title": "Sun Domain Overview",
  "uid": "sun-domain-overview",
  "schemaVersion": 39,
  "version": 1,
  "editable": true,
  "time": { "from": "now-6h", "to": "now" },
  "tags": ["sun"],
  "templating": {
    "list": [
      {
        "name": "workspace",
        "type": "query",
        "datasource": "Loki",
        "query": "label_values(workspace)",
        "refresh": 2,
        "includeAll": false
      },
      {
        "name": "domain",
        "type": "query",
        "datasource": "Loki",
        "query": "label_values({workspace=\"$workspace\"}, domain)",
        "refresh": 2,
        "includeAll": false
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "title": "Request rate by service",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "datasource": "Prometheus",
      "targets": [
        {
          "expr": "sum(rate(sun_svc_requests_total{workspace=\"$workspace\", domain=\"$domain\"}[5m])) by (service)",
          "legendFormat": "{{service}}"
        }
      ]
    },
    {
      "id": 2,
      "title": "5xx error rate by service",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "datasource": "Prometheus",
      "targets": [
        {
          "expr": "sum(rate(sun_svc_requests_total{workspace=\"$workspace\", domain=\"$domain\", status_class=\"5xx\"}[5m])) by (service)",
          "legendFormat": "{{service}}"
        }
      ]
    },
    {
      "id": 3,
      "title": "Scraped targets up, by service",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "datasource": "Prometheus",
      "targets": [
        {
          "expr": "sum(up{workspace=\"$workspace\", domain=\"$domain\"}) by (service)",
          "legendFormat": "{{service}}"
        }
      ]
    },
    {
      "id": 4,
      "title": "Recent logs, this domain",
      "type": "logs",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "datasource": "Loki",
      "targets": [
        { "expr": "{workspace=\"$workspace\", domain=\"$domain\"}" }
      ]
    }
  ]
}|json}

let service_template_json = {json|{
  "title": "Sun Service",
  "uid": "sun-service-template",
  "schemaVersion": 39,
  "version": 1,
  "editable": true,
  "time": { "from": "now-6h", "to": "now" },
  "tags": ["sun"],
  "templating": {
    "list": [
      {
        "name": "workspace",
        "type": "query",
        "datasource": "Loki",
        "query": "label_values(workspace)",
        "refresh": 2,
        "includeAll": false
      },
      {
        "name": "domain",
        "type": "query",
        "datasource": "Loki",
        "query": "label_values({workspace=\"$workspace\"}, domain)",
        "refresh": 2,
        "includeAll": false
      },
      {
        "name": "service",
        "type": "query",
        "datasource": "Loki",
        "query": "label_values({workspace=\"$workspace\", domain=\"$domain\"}, service)",
        "refresh": 2,
        "includeAll": false
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "title": "Request rate",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "datasource": "Prometheus",
      "targets": [
        {
          "expr": "sum(rate(sun_svc_requests_total{workspace=\"$workspace\", domain=\"$domain\", service=\"$service\"}[5m])) by (route, method)",
          "legendFormat": "{{method}} {{route}}"
        }
      ]
    },
    {
      "id": 2,
      "title": "p95 request duration",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "datasource": "Prometheus",
      "targets": [
        {
          "expr": "histogram_quantile(0.95, sum(rate(sun_svc_request_duration_seconds_bucket{workspace=\"$workspace\", domain=\"$domain\", service=\"$service\"}[5m])) by (le, route))",
          "legendFormat": "{{route}}"
        }
      ]
    },
    {
      "id": 3,
      "title": "Pod up",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "datasource": "Prometheus",
      "targets": [
        {
          "expr": "up{workspace=\"$workspace\", domain=\"$domain\", service=\"$service\"}",
          "legendFormat": "{{pod}}"
        }
      ]
    },
    {
      "id": 4,
      "title": "Logs",
      "type": "logs",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "datasource": "Loki",
      "targets": [
        { "expr": "{workspace=\"$workspace\", domain=\"$domain\", service=\"$service\"}" }
      ]
    }
  ]
}|json}

(* OBS-038: deploy/release timeline, sourced from OBS-037's `event=deploy`
   Loki log lines pushed directly by `sun deploy` (cli/sun/bin/
   cmd_deploy_event.ml) rather than tailed from a pod by Alloy. The push
   sets `service` to the deployed service's real name (Obs_eio.create's
   built-in stream label, same convention every real app pod uses) and
   promotes workspace/domain/primitive/release to real Loki stream labels
   too, matching Alloy's own taxonomy-label promotion for application pod
   logs -- deploy events land in that service's own Loki stream, not a
   separate synthetic one, distinguished by the `event="deploy"` logfmt
   field every deploy-event line carries. The query below uses the same
   `{workspace=..., domain=..., service=...}` selector shape as every
   other dashboard's logs panel. *)
let release_timeline_json = {json|{
  "title": "Sun Release Timeline",
  "uid": "sun-release-timeline",
  "schemaVersion": 39,
  "version": 1,
  "editable": true,
  "time": { "from": "now-24h", "to": "now" },
  "tags": ["sun"],
  "templating": {
    "list": [
      {
        "name": "workspace",
        "type": "query",
        "datasource": "Loki",
        "query": "label_values(workspace)",
        "refresh": 2,
        "includeAll": false
      },
      {
        "name": "domain",
        "type": "query",
        "datasource": "Loki",
        "query": "label_values({workspace=\"$workspace\"}, domain)",
        "refresh": 2,
        "includeAll": false
      },
      {
        "name": "service",
        "type": "query",
        "datasource": "Loki",
        "query": "label_values({workspace=\"$workspace\", domain=\"$domain\"}, service)",
        "refresh": 2,
        "includeAll": false
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "title": "Deploy / release events",
      "type": "logs",
      "gridPos": { "h": 12, "w": 24, "x": 0, "y": 0 },
      "datasource": "Loki",
      "targets": [
        {
          "expr": "{workspace=\"$workspace\", domain=\"$domain\", service=\"$service\"} | logfmt | event=\"deploy\""
        }
      ]
    }
  ]
}|json}

let dashboard_configmap_yaml ~namespace =
  configmap_yaml
    ~name:"sun-grafana-dashboards"
    ~namespace
    ~labels:["grafana_dashboard", "1"]
    ~data:[
      "workspace-overview.json", workspace_overview_json;
      "domain-overview.json", domain_overview_json;
      "service-template.json", service_template_json;
      "release-timeline.json", release_timeline_json;
    ]

let prometheus_datasource_configmap_yaml ~namespace =
  configmap_yaml
    ~name:"grafana-prometheus-datasource"
    ~namespace
    ~labels:["grafana_datasource", "1"]
    ~data:["prometheus.yaml", prometheus_datasource_yaml ~namespace]

(* OBS-039: loki-stack's bundled Grafana subchart auto-provisioned a "Loki"
   datasource itself (a chart-internal template, not just the generic
   sidecar-ConfigMap convention). Now that `sun dev up` installs the
   standalone `grafana` chart instead, that auto-provisioning is gone and
   must be replaced explicitly -- every dashboard above references a
   datasource named exactly "Loki". Matches
   platform/infra/base's helm_release.grafana bundle:
   kubernetes_config_map.grafana_loki_datasource. *)
let loki_datasource_yaml =
  {|apiVersion: 1
datasources:
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    isDefault: false|}

let loki_datasource_configmap_yaml ~namespace =
  configmap_yaml
    ~name:"grafana-loki-datasource"
    ~namespace
    ~labels:["grafana_datasource", "1"]
    ~data:["loki.yaml", loki_datasource_yaml]

(* OBS-039: Alloy's log-shipping River config for `sun dev up`, matching
   platform/infra/base/alloy/logs.alloy.tftpl's local-profile rendering
   (push straight to the in-cluster Loki, no external/basic-auth branch --
   `sun dev up` has no "external backend" concept). Validated with the real
   `alloy validate` binary (grafana/alloy:v1.12.1) during OBS-039's
   implementation; keep this in sync with the .tftpl by hand if either
   changes -- Terraform's HCL template language has no OCaml equivalent to
   share the source with directly. *)
let alloy_config_river =
  {river|// Cluster-wide pod log shipping for `sun dev up`. Alloy's Promtail
// successor: this is real River config (Alloy's config language), not
// Promtail-shaped YAML. See OBS-039 for the migration this replaces
// (promtail.enabled -> Alloy). Kept in sync by hand with
// platform/infra/base/alloy/logs.alloy.tftpl's local-profile rendering.

discovery.kubernetes "pods" {
  role = "pod"
}

discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets

  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }

  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }

  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    target_label  = "container"
  }

  rule {
    source_labels = ["__meta_kubernetes_pod_label_workspace"]
    target_label  = "workspace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_domain"]
    target_label  = "domain"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_service"]
    target_label  = "service"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_primitive"]
    target_label  = "primitive"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_release"]
    target_label  = "release"
  }
}

loki.source.kubernetes "pods" {
  targets    = discovery.relabel.pods.output
  forward_to = [loki.write.default.receiver]
}

loki.write "default" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}
|river}

let alloy_values_yaml =
  Printf.sprintf
    {|alloy:
  configMap:
    content: |-
%s
|}
    (indent_block alloy_config_river)
