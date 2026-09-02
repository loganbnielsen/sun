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

# ── Loki + Grafana ────────────────────────────────────────────────────────── #

locals {
  # "external": promtail ships straight to the user-supplied Loki endpoint;
  # no local Loki/Grafana needed. "local"/"self_hosted_durable": promtail
  # ships to the in-cluster Loki, which self_hosted_durable then backs with
  # S3 instead of local disk.
  loki_install_local = var.observability_backend != "external"

  loki_promtail_clients = var.observability_backend == "external" ? [
    merge(
      { url = var.external_loki_url },
      var.external_loki_username != "" ? {
        basic_auth = { username = var.external_loki_username, password = var.external_loki_password }
      } : {}
    )
    ] : [
    { url = "http://loki:3100/loki/api/v1/push" }
  ]

  # Grafana's documented object-storage-backed architecture: chunks + the
  # boltdb-shipper index both in S3. loki_s3_bucket/aws_region come from
  # platform/infra/aws's loki_s3_bucket/loki_irsa_arn outputs (OBS-006).
  #
  # Always computed (not a `cond ? {...} : {}` ternary) and gated instead via
  # a list-level `concat()` in helm_release.loki's `values` below --
  # Terraform's conditional expressions require both branches to unify to
  # the same type, which breaks for two object literals with different
  # attribute sets. A list of yamlencode() strings has no such problem since
  # every branch is just `list(string)`.
  loki_object_storage_config = {
    loki = {
      config = {
        storage_config = {
          aws = {
            s3               = "s3://${var.aws_region}/${var.loki_s3_bucket}"
            s3forcepathstyle = false
          }
          boltdb_shipper = {
            active_index_directory = "/data/loki/boltdb-shipper-active"
            cache_location         = "/data/loki/boltdb-shipper-cache"
            shared_store           = "s3"
          }
        }
        schema_config = {
          configs = [{
            from         = "2024-01-01"
            store        = "boltdb-shipper"
            object_store = "s3"
            schema       = "v11"
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
}

# promtail.enabled defaults to true in loki-stack (it scrapes every pod's
# stdout/stderr cluster-wide via a DaemonSet, relabeling namespace/pod/
# container/app from Kubernetes metadata). Sun depends on this for the
# failures obs-loki-eio's app-push logging structurally can't see: OOMKilled,
# CrashLoopBackOff, a crash before the app ever logs (OBS-004). Declared
# explicitly rather than left as an implicit chart default so a future chart
# bump can't silently turn it off without showing up in a diff.
resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  version    = "2.10.2"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  set {
    name  = "grafana.enabled"
    value = tostring(local.loki_install_local)
  }
  set {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }
  set {
    name  = "loki.enabled"
    value = tostring(local.loki_install_local)
  }
  set {
    name  = "loki.persistence.enabled"
    value = tostring(var.loki_persistent_storage)
  }
  set {
    name  = "promtail.enabled"
    value = "true"
  }

  values = concat(
    [yamlencode({ promtail = { config = { clients = local.loki_promtail_clients } } })],
    var.observability_backend == "self_hosted_durable" ? [yamlencode(local.loki_object_storage_config)] : []
  )

  depends_on = [terraform_data.observability_backend_validation]
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
              name = "loki-grafana"
              port { number = 80 }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.loki, helm_release.ingress_nginx]
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
