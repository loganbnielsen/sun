# platform/infra/base — cluster-agnostic platform bootstrap
#
# Installs all Sun platform components onto an existing Kubernetes cluster
# using Helm. Run this once per cluster after provisioning (platform/infra/aws or
# platform/infra/gcp). The cluster kubeconfig must be active before applying.
#
# Components installed:
#   cert-manager       — TLS certificate automation (Let's Encrypt)
#   ingress-nginx      — Ingress controller
#   Argo CD            — GitOps continuous delivery
#   Redpanda           — Kafka-compatible broker + schema registry
#   PostgreSQL         — Primary database (use platform/infra/aws RDS for production)
#   Loki + Grafana     — Log aggregation and dashboards
#   Alloy              — Cluster-wide pod log shipping (Promtail's successor)
#   Prometheus         — Metrics collection and Pushgateway

terraform {
  required_version = ">= 1.6"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
  }
}

# ── Namespaces ────────────────────────────────────────────────────────────── #

resource "kubernetes_namespace" "cert_manager" {
  metadata { name = "cert-manager" }
}

resource "kubernetes_namespace" "ingress_nginx" {
  metadata { name = "ingress-nginx" }
}

resource "kubernetes_namespace" "argocd" {
  metadata { name = "argocd" }
}

resource "kubernetes_namespace" "redpanda" {
  metadata { name = "redpanda" }
}

resource "kubernetes_namespace" "postgresql" {
  metadata { name = "postgresql" }
  count = var.install_postgresql ? 1 : 0
}

resource "kubernetes_namespace" "monitoring" {
  metadata { name = "monitoring" }
}

resource "terraform_data" "observability_backend_validation" {
  input = var.observability_backend

  lifecycle {
    precondition {
      condition = var.observability_backend != "external" || (
        trimspace(var.external_loki_url) != "" &&
        trimspace(var.external_prometheus_remote_write_url) != ""
      )
      error_message = "observability_backend = \"external\" requires external_loki_url and external_prometheus_remote_write_url."
    }

    precondition {
      condition = var.observability_backend != "external" || (
        (trimspace(var.external_loki_username) == "" && trimspace(var.external_loki_password) == "") ||
        (trimspace(var.external_loki_username) != "" && trimspace(var.external_loki_password) != "")
      )
      error_message = "external_loki_username and external_loki_password must be set together."
    }

    precondition {
      condition = var.observability_backend != "external" || (
        (trimspace(var.external_prometheus_username) == "" && trimspace(var.external_prometheus_password) == "") ||
        (trimspace(var.external_prometheus_username) != "" && trimspace(var.external_prometheus_password) != "")
      )
      error_message = "external_prometheus_username and external_prometheus_password must be set together."
    }

    precondition {
      condition = var.observability_backend != "self_hosted_durable" || (
        trimspace(var.loki_s3_bucket) != "" &&
        trimspace(var.loki_irsa_role_arn) != "" &&
        trimspace(var.thanos_s3_bucket) != "" &&
        trimspace(var.thanos_irsa_role_arn) != ""
      )
      error_message = "observability_backend = \"self_hosted_durable\" requires loki_s3_bucket, loki_irsa_role_arn, thanos_s3_bucket, and thanos_irsa_role_arn."
    }

    precondition {
      condition     = var.observability_backend != "self_hosted_durable" || var.cloud_provider == "aws"
      error_message = "observability_backend = \"self_hosted_durable\" is currently supported only on AWS/EKS because it uses IRSA. GCP support requires Workload Identity wiring."
    }
  }
}

# ── cert-manager ──────────────────────────────────────────────────────────── #

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.14.4"
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name

  set {
    name  = "installCRDs"
    value = "true"
  }
}

# ── ingress-nginx ─────────────────────────────────────────────────────────── #

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.10.1"
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name

  set {
    name  = "controller.service.type"
    value = var.ingress_service_type
  }

  depends_on = [helm_release.cert_manager]
}

# ── Argo CD ───────────────────────────────────────────────────────────────── #

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "6.7.3"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  # Disable TLS termination at Argo CD — handled by ingress-nginx
  set {
    name  = "server.insecure"
    value = "true"
  }
}

# Expose Argo CD UI via Ingress
resource "kubernetes_ingress_v1" "argocd" {
  metadata {
    name      = "argocd-server"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
      "cert-manager.io/cluster-issuer"           = var.cluster_issuer
    }
  }

  spec {
    ingress_class_name = "nginx"

    tls {
      hosts       = ["argocd.${var.base_domain}"]
      secret_name = "argocd-tls"
    }

    rule {
      host = "argocd.${var.base_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "argocd-server"
              port { number = 80 }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.argocd, helm_release.ingress_nginx]
}

# ── Redpanda (Kafka + schema registry) ───────────────────────────────────── #

resource "helm_release" "redpanda" {
  name       = "redpanda"
  repository = "https://charts.redpanda.com"
  chart      = "redpanda"
  version    = "5.8.12"
  namespace  = kubernetes_namespace.redpanda.metadata[0].name
  timeout    = 600

  values = [
    yamlencode({
      statefulset = { replicas = var.redpanda_replicas }
      resources = {
        cpu    = { cores = var.redpanda_cpu_cores }
        memory = { container = { max = var.redpanda_memory } }
      }
      storage = {
        persistentVolume = { enabled = var.redpanda_persistent_storage }
      }
      tls = { enabled = false }
      config = {
        cluster = {
          auto_create_topics_enabled = true
        }
      }
    })
  ]
}

# ── PostgreSQL (in-cluster; set install_postgresql=false to use RDS/Cloud SQL) #

resource "helm_release" "postgresql" {
  count      = var.install_postgresql ? 1 : 0
  name       = "postgresql"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "postgresql"
  version    = "15.5.1"
  namespace  = kubernetes_namespace.postgresql[0].metadata[0].name

  set {
    name  = "auth.postgresPassword"
    value = var.postgres_password
  }
  set {
    name  = "auth.database"
    value = "dev"
  }
  set {
    name  = "primary.persistence.enabled"
    value = tostring(var.postgres_persistent_storage)
  }
}

# ── Loki + Grafana + Alloy ──────────────────────────────────────────────── #
#
# OBS-039: loki-stack (deprecated by Grafana Labs, bundled Promtail which
# reached end-of-life March 2026) replaced by the split, currently
# maintained chart set: `loki` (Loki only), `grafana` (standalone, no
# longer a loki-stack subchart), and `alloy` (Promtail's official
# successor, Loki-log-shipping role only -- see alloy/logs.alloy.tftpl).

locals {
  # "external": Alloy ships straight to the user-supplied Loki endpoint; no
  # local Loki/Grafana needed. "local"/"self_hosted_durable": Alloy ships to
  # the in-cluster Loki, which self_hosted_durable then backs with S3
  # instead of local disk.
  loki_install_local = var.observability_backend != "external"

  # Alloy's loki.write target -- installed unconditionally (unlike Loki and
  # Grafana), same as promtail.enabled used to be regardless of
  # observability_backend.
  loki_push_url                 = var.observability_backend == "external" ? var.external_loki_url : "http://loki:3100/loki/api/v1/push"
  loki_push_basic_auth_username = var.observability_backend == "external" ? var.external_loki_username : ""
  loki_push_basic_auth_password = var.observability_backend == "external" ? var.external_loki_password : ""

  # OBS-008: promote the label taxonomy (Sun_cli_manifest_yaml's
  # render_taxonomy_labels) from pod labels into Loki stream labels via
  # Alloy's discovery.relabel component -- see alloy/logs.alloy.tftpl.
  observability_taxonomy_labels = ["workspace", "domain", "service", "primitive", "release"]

  # The `loki` chart's own object-storage-backed architecture: chunks + the
  # index both in S3, addressed as bucketNames/s3 rather than loki-stack's
  # nested storage_config.aws/boltdb_shipper shape (confirmed via
  # `helm show values grafana-community/loki --version 18.12.1`).
  # loki_s3_bucket/aws_region come from platform/infra/aws's
  # loki_s3_bucket/loki_irsa_arn outputs (OBS-006). serviceAccount is now a
  # top-level chart value (the new chart has no bundled Grafana to
  # disambiguate it from).
  loki_object_storage_config = {
    loki = {
      storage = {
        type = "s3"
        bucketNames = {
          chunks = var.loki_s3_bucket
          ruler  = var.loki_s3_bucket
        }
        s3 = {
          region           = var.aws_region
          s3ForcePathStyle = false
        }
      }
      schemaConfig = {
        configs = [{
          from         = "2024-01-01"
          store        = "tsdb"
          object_store = "s3"
          schema       = "v13"
          index = {
            prefix = "index_"
            period = "24h"
          }
        }]
      }
    }
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = var.loki_irsa_role_arn
      }
    }
  }
}

# Loki-only chart (community-maintained, replacing the deprecated
# loki-stack). No local install for the "external" backend -- there's
# nothing to browse locally when logs ship straight to the user's own
# endpoint. Single Monolithic replica matches loki-stack's single-instance
# footprint ("Dev mirrors prod exactly" -- same shape at both scales).
#
# Chart moved from grafana.github.io/helm-charts to
# grafana-community.github.io/helm-charts (confirmed via `helm search repo`
# against both hosts: the old repo's `grafana/loki` and `grafana/grafana`
# entries are `deprecated: true`; grafana-community's are not). Alloy has
# not moved -- it stays on grafana.github.io/helm-charts, see
# helm_release.alloy below.
resource "helm_release" "loki" {
  count = local.loki_install_local ? 1 : 0

  name       = "loki"
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "loki"
  version    = "18.12.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  # The chart's own recommended default is SimpleScalable (write/read/backend
  # replicas default to 3 each even though deploymentMode itself defaults to
  # "Monolithic") -- explicit zeroing is required to actually run
  # single-binary mode, not just leaving the top-level deploymentMode at its
  # default. Verified via `helm template`: omitting these renders a
  # validate.yaml failure ("Cannot run scalable targets ... without an
  # object storage backend") under the filesystem-storage `local` profile.
  set {
    name  = "deploymentMode"
    value = "Monolithic"
  }
  set {
    name  = "singleBinary.replicas"
    value = "1"
  }
  set {
    name  = "write.replicas"
    value = "0"
  }
  set {
    name  = "read.replicas"
    value = "0"
  }
  set {
    name  = "backend.replicas"
    value = "0"
  }
  set {
    name  = "singleBinary.persistence.enabled"
    value = tostring(var.loki_persistent_storage)
  }
  # No nginx gateway in front of Loki -- loki-stack never had one either;
  # Alloy/Sun's CLI (sun_cli_status.ml's `kubectl port-forward ... svc/loki
  # 3100:3100`) both talk to the singleBinary Service directly.
  set {
    name  = "gateway.enabled"
    value = "false"
  }
  # Single-tenant, matching loki-stack's default -- Alloy pushes with no
  # X-Scope-OrgID, which the new chart's auth_enabled: true default would
  # reject.
  set {
    name  = "loki.auth_enabled"
    value = "false"
  }
  set {
    name  = "loki.storage.type"
    value = var.observability_backend == "self_hosted_durable" ? "s3" : "filesystem"
  }
  # useTestSchema is the chart's documented escape hatch for a real
  # schemaConfig when running filesystem storage without object-store-backed
  # durability -- exactly the `local` profile's use case.
  set {
    name  = "loki.useTestSchema"
    value = tostring(var.observability_backend != "self_hosted_durable")
  }

  values = var.observability_backend == "self_hosted_durable" ? [yamlencode(local.loki_object_storage_config)] : []

  depends_on = [terraform_data.observability_backend_validation]
}

# Grafana, standalone (no longer a loki-stack subchart). Gated identically
# to helm_release.loki -- no local Grafana to browse when shipping to an
# external backend.
resource "helm_release" "grafana" {
  count = local.loki_install_local ? 1 : 0

  name       = "grafana"
  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "grafana"
  version    = "13.2.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  set {
    name  = "adminPassword"
    value = var.grafana_admin_password
  }
  # OBS-011: dashboard/datasource sidecar-ConfigMap loading is a feature of
  # the Grafana chart itself (unchanged behavior from loki-stack's bundled
  # subchart), just moved from the nested `grafana.sidecar.*` passthrough
  # naming to this chart's own top-level `sidecar.*`. Unlike loki-stack,
  # this standalone chart defaults sidecar.datasources.enabled to false, so
  # it now needs the same explicit `set` treatment dashboards already had.
  set {
    name  = "sidecar.dashboards.enabled"
    value = "true"
  }
  set {
    name  = "sidecar.datasources.enabled"
    value = "true"
  }

  depends_on = [terraform_data.observability_backend_validation]
}

# Alloy -- Promtail's official successor (Promtail itself reached
# end-of-life March 2026), scoped in this ticket to log shipping only (see
# OBS-039's Non-goal; metrics/traces collection is a future OBS-041
# connection point). Installed unconditionally, matching
# promtail.enabled = true's old unconditional-across-all-backends behavior:
# even the "external" profile needs something scraping and forwarding pod
# logs.
#
# alloy/logs.alloy.tftpl is real Alloy River config (discovery.kubernetes +
# discovery.relabel + loki.source.kubernetes + loki.write), not
# Promtail-shaped YAML -- Alloy's config language has no scrape_configs/
# relabel_configs compatibility surface. loki.source.kubernetes tails pod
# logs via the Kubernetes API rather than a hostPath volume mount, so no
# extra RBAC or `alloy.mounts.*` values are needed beyond this chart's
# default ClusterRole (verified via `helm show values`: the default
# `rbac.rules` already grants `pods`, `pods/log`, and `namespaces`
# get/list/watch).
resource "helm_release" "alloy" {
  name       = "alloy"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = "1.12.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [yamlencode({
    alloy = {
      configMap = {
        content = templatefile("${path.module}/alloy/logs.alloy.tftpl", {
          loki_push_url                 = local.loki_push_url
          loki_push_basic_auth_username = local.loki_push_basic_auth_username
          loki_push_basic_auth_password = local.loki_push_basic_auth_password
          taxonomy_labels               = local.observability_taxonomy_labels
        })
      }
    }
  })]

  depends_on = [terraform_data.observability_backend_validation]
}

# Loki datasource for Grafana. loki-stack's bundled Grafana subchart
# auto-provisioned this itself (a chart-internal template, not just the
# generic sidecar-ConfigMap convention) -- now that Grafana and Loki are
# separate charts with no bundling relationship, that auto-provisioning is
# gone and must be replaced explicitly, the same way
# grafana_prometheus_datasource below already wires up Prometheus. Every
# dashboard in dashboards/*.json references a datasource named exactly
# "Loki".
resource "kubernetes_config_map" "grafana_loki_datasource" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "grafana-loki-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_datasource = "1" }
  }

  data = {
    "loki.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Loki"
        type      = "loki"
        access    = "proxy"
        url       = "http://loki:3100"
        isDefault = false
      }]
    })
  }

  depends_on = [helm_release.grafana]
}

# Prometheus datasource for Grafana, loaded via the same sidecar-ConfigMap
# mechanism the chart already uses (sidecar.datasources.enabled: true, set
# explicitly on helm_release.grafana above; label key "grafana_datasource"
# is that sidecar's own default, unchanged).
resource "kubernetes_config_map" "grafana_prometheus_datasource" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "grafana-prometheus-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_datasource = "1" }
  }

  data = {
    "prometheus.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "Prometheus"
        type      = "prometheus"
        access    = "proxy"
        url       = "http://prometheus-server.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:80"
        isDefault = false
      }]
    })
  }

  depends_on = [helm_release.grafana]
}

# OBS-011: the lazy version -- two dashboards total (workspace overview,
# one $domain/$service-templated service dashboard), not one generated file
# per domain/service. Adding a new service requires zero Sun-side dashboard
# changes; Grafana's own template variables (populated from live Prometheus/
# Loki label values, not a static list Sun maintains) do the scoping.
# OBS-036 adds a third, $domain-only dashboard for the gap between
# workspace-wide and single-service views: per-service breakdowns within
# one domain, using the same live-label-driven templating.
resource "kubernetes_config_map" "grafana_dashboards" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "sun-grafana-dashboards"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }

  data = {
    "workspace-overview.json" = file("${path.module}/dashboards/workspace-overview.json")
    "service-template.json"   = file("${path.module}/dashboards/service-template.json")
    "domain-overview.json"    = file("${path.module}/dashboards/domain-overview.json")
  }

  depends_on = [helm_release.grafana]
}

# Grafana Ingress — no local Grafana to expose when shipping to an external
# backend.
resource "kubernetes_ingress_v1" "grafana" {
  count = local.loki_install_local ? 1 : 0

  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
      "cert-manager.io/cluster-issuer"           = var.cluster_issuer
    }
  }

  spec {
    ingress_class_name = "nginx"

    tls {
      hosts       = ["grafana.${var.base_domain}"]
      secret_name = "grafana-tls"
    }

    rule {
      host = "grafana.${var.base_domain}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "grafana"
              port { number = 80 }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.grafana, helm_release.ingress_nginx]
}

# ── Prometheus + Pushgateway ──────────────────────────────────────────────── #

locals {
  prometheus_thanos_enabled = var.observability_backend == "self_hosted_durable"

  prometheus_remote_write = var.observability_backend == "external" ? [
    merge(
      { url = var.external_prometheus_remote_write_url },
      var.external_prometheus_username != "" ? {
        basic_auth = { username = var.external_prometheus_username, password = var.external_prometheus_password }
      } : {}
    )
  ] : []

  # Thanos sidecar shares the prometheus-server pod's own "storage-volume" and
  # uploads TSDB blocks to S3. Thanos Query reads current blocks from the
  # sidecar and historical blocks from storegateway below.
  #
  # Always computed and gated via `concat()` in the values list below, same
  # reasoning as loki_object_storage_config above: a `cond ? {...} : {}`
  # ternary between object literals with different attribute sets fails
  # Terraform's type unification, but list(string) branches never do.
  prometheus_thanos_server_fields = {
    server = {
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = var.thanos_irsa_role_arn
        }
      }
      service = {
        gRPC = { enabled = true, servicePort = 10901 }
      }
      extraSecretMounts = [{
        name       = "thanos-objstore-config"
        mountPath  = "/etc/thanos"
        subPath    = ""
        secretName = "thanos-objstore-config"
        readOnly   = true
      }]
      sidecarContainers = {
        thanos-sidecar = {
          image = "thanosio/thanos:v0.35.1"
          args = [
            "sidecar",
            "--tsdb.path=/data",
            "--prometheus.url=http://127.0.0.1:9090",
            "--objstore.config-file=/etc/thanos/objstore.yml",
            "--http-address=0.0.0.0:10902",
            "--grpc-address=0.0.0.0:10901",
          ]
          volumeMounts = [
            { name = "storage-volume", mountPath = "/data" },
            { name = "thanos-objstore-config", mountPath = "/etc/thanos", readOnly = true }
          ]
          ports = [
            { containerPort = 10902, name = "http-sidecar" },
            { containerPort = 10901, name = "grpc" }
          ]
        }
      }
    }
  }
}

# Thanos's object-store config file, mounted into the sidecar and Bitnami
# Thanos components. IRSA supplies credentials; no access keys in this config.
resource "kubernetes_secret" "thanos_objstore_config" {
  count = local.prometheus_thanos_enabled ? 1 : 0

  metadata {
    name      = "thanos-objstore-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "objstore.yml" = yamlencode({
      type = "S3"
      config = {
        bucket   = var.thanos_s3_bucket
        endpoint = "s3.${var.aws_region}.amazonaws.com"
        region   = var.aws_region
      }
    })
  }
}

resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  version    = "25.20.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  set {
    name  = "server.persistentVolume.enabled"
    value = tostring(var.observability_backend == "external" ? false : var.prometheus_persistent_storage)
  }
  set {
    name = "server.retention"
    # "external": local storage is just a remote_write buffer, not the
    # durable store, so a short retention is enough.
    value = var.observability_backend == "external" ? "2h" : "15d"
  }
  set {
    name  = "pushgateway.enabled"
    value = "true"
  }
  set {
    name  = "alertmanager.enabled"
    value = "false"
  }

  values = concat(
    [yamlencode({ server = { remoteWrite = local.prometheus_remote_write } })],
    local.prometheus_thanos_enabled ? [yamlencode(local.prometheus_thanos_server_fields)] : []
  )

  depends_on = [
    kubernetes_secret.thanos_objstore_config,
    terraform_data.observability_backend_validation
  ]
}

# Thanos read path for durable metrics. Keep it to the components needed for
# queryable history: query, storegateway, and compactor.
resource "helm_release" "thanos" {
  count      = local.prometheus_thanos_enabled ? 1 : 0
  name       = "thanos"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "thanos"
  version    = "17.3.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  set {
    name  = "query.enabled"
    value = "true"
  }
  set {
    name  = "query.dnsDiscovery.enabled"
    value = "false"
  }
  set {
    name  = "query.stores[0]"
    value = "prometheus-server.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:10901"
  }
  set {
    name  = "query.stores[1]"
    value = "thanos-storegateway.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:10901"
  }
  set {
    name  = "existingObjstoreSecret"
    value = kubernetes_secret.thanos_objstore_config[0].metadata[0].name
  }
  set {
    name  = "storegateway.enabled"
    value = "true"
  }
  set {
    name  = "compactor.enabled"
    value = "true"
  }
  set {
    name  = "compactor.retentionResolutionRaw"
    value = "${var.prometheus_raw_retention_days}d"
  }
  set {
    name  = "compactor.retentionResolution5m"
    value = "${var.thanos_retention_5m_days}d"
  }
  set {
    name  = "compactor.retentionResolution1h"
    value = "${var.thanos_retention_1h_days}d"
  }
  set {
    name  = "storegateway.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.thanos_irsa_role_arn
  }
  set {
    name  = "compactor.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.thanos_irsa_role_arn
  }
  set {
    name  = "receive.enabled"
    value = "false"
  }
  set {
    name  = "ruler.enabled"
    value = "false"
  }
  set {
    name  = "bucketweb.enabled"
    value = "false"
  }
  set {
    name  = "queryFrontend.enabled"
    value = "false"
  }

  depends_on = [
    helm_release.prometheus,
    terraform_data.observability_backend_validation
  ]
}
