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

let dashboard_configmap_yaml ~namespace =
  configmap_yaml
    ~name:"sun-grafana-dashboards"
    ~namespace
    ~labels:["grafana_dashboard", "1"]
    ~data:[
      "workspace-overview.json", workspace_overview_json;
      "domain-overview.json", domain_overview_json;
      "service-template.json", service_template_json;
    ]

let prometheus_datasource_configmap_yaml ~namespace =
  configmap_yaml
    ~name:"grafana-prometheus-datasource"
    ~namespace
    ~labels:["grafana_datasource", "1"]
    ~data:["prometheus.yaml", prometheus_datasource_yaml ~namespace]
