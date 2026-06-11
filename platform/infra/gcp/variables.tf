variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "GKE cluster name and resource name prefix (e.g. acme-prod)"
  type        = string
}

variable "base_domain" {
  description = "Base domain for the cluster (e.g. acme.com)"
  type        = string
}

# VPC CIDRs
variable "nodes_cidr" {
  type    = string
  default = "10.0.0.0/20"
}

variable "pods_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "services_cidr" {
  type    = string
  default = "10.2.0.0/20"
}

variable "master_cidr" {
  description = "CIDR for the GKE control plane (must be /28, cannot overlap other ranges)"
  type        = string
  default     = "172.16.0.0/28"
}

# Cloud SQL
variable "sql_tier" {
  description = "Cloud SQL machine tier"
  type        = string
  default     = "db-g1-small"
}

variable "sql_disk_gb" {
  type    = number
  default = 20
}

variable "sql_high_availability" {
  description = "Enable Cloud SQL high availability (REGIONAL). Doubles cost."
  type        = bool
  default     = false
}

variable "sql_deletion_protection" {
  description = "Enable Cloud SQL deletion protection."
  type        = bool
  default     = true
}

variable "db_password" {
  description = "PostgreSQL admin password"
  type        = string
  sensitive   = true
}

# DNS
variable "create_dns_zone" {
  description = "Create a new Cloud DNS managed zone for base_domain."
  type        = bool
  default     = true
}
