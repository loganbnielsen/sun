variable "base_domain" {
  description = "Base domain for Ingress resources, e.g. mycompany.com. Subdomains argocd.*, grafana.* are created."
  type        = string
}

variable "cluster_issuer" {
  description = "cert-manager ClusterIssuer name for TLS certificates."
  type        = string
  default     = "letsencrypt-prod"
}

variable "ingress_service_type" {
  description = "Kubernetes Service type for the ingress-nginx controller. Use LoadBalancer for cloud clusters, NodePort for k3d/local."
  type        = string
  default     = "LoadBalancer"
}

# Redpanda
variable "redpanda_replicas" {
  description = "Number of Redpanda broker replicas."
  type        = number
  default     = 3
}

variable "redpanda_cpu_cores" {
  description = "CPU cores per Redpanda broker."
  type        = number
  default     = 2
}

variable "redpanda_memory" {
  description = "Memory limit per Redpanda broker (e.g. 4Gi)."
  type        = string
  default     = "4Gi"
}

variable "redpanda_persistent_storage" {
  description = "Enable persistent volumes for Redpanda. Disable for ephemeral dev clusters."
  type        = bool
  default     = true
}

# PostgreSQL (in-cluster)
variable "install_postgresql" {
  description = "Install in-cluster PostgreSQL. Set false when using RDS or Cloud SQL."
  type        = bool
  default     = false
}

variable "postgres_password" {
  description = "PostgreSQL admin password. Ignored when install_postgresql=false."
  type        = string
  default     = "dev"
  sensitive   = true
}

variable "postgres_persistent_storage" {
  description = "Enable persistent volumes for PostgreSQL."
  type        = bool
  default     = true
}

# Grafana
variable "grafana_admin_password" {
  description = "Grafana admin password."
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "loki_persistent_storage" {
  description = "Enable persistent volumes for Loki."
  type        = bool
  default     = true
}

variable "prometheus_persistent_storage" {
  description = "Enable persistent volumes for Prometheus."
  type        = bool
  default     = true
}

# ── Observability backend profile (OBS-005/006/007) ──────────────────────── #
#
# Sun does not choose a vendor here. "local" is today's behavior; "external"
# points at infrastructure the user already has; "self_managed_durable" backs
# Loki/Prometheus with S3 via platform/infra/aws (OBS-006 logs, OBS-007
# metrics via a Thanos sidecar) — AWS only for now, see loki_s3_bucket etc.
# below. Selecting self_managed_durable without setting those variables
# leaves Loki/Prometheus pointed at a bucket/role that doesn't exist.

variable "observability_backend" {
  description = <<-EOT
    Observability backend profile:
      local                — in-cluster Loki + Grafana + Prometheus (default).
      external             — point promtail/Prometheus remote_write at a
                              user-supplied endpoint; skip installing local
                              Loki + Grafana (Prometheus still runs to scrape
                              and forward, with minimal local retention).
      self_managed_durable — same in-cluster components as "local", but backed
                              by durable storage provisioned in
                              platform/infra/aws (see OBS-006/OBS-007).
  EOT
  type        = string
  default     = "local"
  validation {
    condition     = contains(["local", "external", "self_managed_durable"], var.observability_backend)
    error_message = "observability_backend must be one of: local, external, self_managed_durable."
  }
}

variable "external_loki_url" {
  description = "Loki push URL for the \"external\" profile, e.g. https://logs-prod-000.grafana.net/loki/api/v1/push. Required when observability_backend = \"external\"."
  type        = string
  default     = ""
}

variable "external_loki_username" {
  description = "Basic auth username for external_loki_url (e.g. a Grafana Cloud tenant ID). Leave empty for an endpoint that doesn't require auth."
  type        = string
  default     = ""
}

variable "external_loki_password" {
  description = "Basic auth password/API key for external_loki_url."
  type        = string
  default     = ""
  sensitive   = true
}

variable "external_prometheus_remote_write_url" {
  description = "Prometheus remote_write URL for the \"external\" profile. Required when observability_backend = \"external\"."
  type        = string
  default     = ""
}

variable "external_prometheus_username" {
  description = "Basic auth username for external_prometheus_remote_write_url."
  type        = string
  default     = ""
}

variable "external_prometheus_password" {
  description = "Basic auth password/API key for external_prometheus_remote_write_url."
  type        = string
  default     = ""
  sensitive   = true
}

# ── self_managed_durable (AWS only) — from platform/infra/aws's outputs ──── #
# platform/infra/aws and platform/infra/base are separate Terraform states
# with no automatic remote-state link (same pattern already used for
# cert_manager_irsa_role_arn) — pass these by hand from `terraform output`.

variable "aws_region" {
  description = "AWS region the S3 buckets live in (self_managed_durable profile)."
  type        = string
  default     = "us-east-1"
}

variable "loki_s3_bucket" {
  description = "S3 bucket for durable Loki storage. From platform/infra/aws's loki_s3_bucket output."
  type        = string
  default     = ""
}

variable "loki_irsa_role_arn" {
  description = "IAM role ARN for Loki's S3 access. From platform/infra/aws's loki_irsa_arn output."
  type        = string
  default     = ""
}

variable "thanos_s3_bucket" {
  description = "S3 bucket for durable Prometheus/Thanos storage. From platform/infra/aws's thanos_s3_bucket output."
  type        = string
  default     = ""
}

variable "thanos_irsa_role_arn" {
  description = "IAM role ARN for the Thanos sidecar's S3 access. From platform/infra/aws's thanos_irsa_arn output."
  type        = string
  default     = ""
}
