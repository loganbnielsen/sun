# Minimal-footprint override for live smoke-testing platform/infra/aws/ —
# NOT for real workspaces. Cuts node cost from ~$0.29/hr (3x m6i.large) to
# ~$0.02/hr (1x t3.small); EKS control plane's flat $0.10/hr still applies
# regardless of node sizing.
#
# Usage:
#   sun cloud init --aws --var-file platform/infra/aws/smoke-test.tfvars \
#     -var="cluster_name=sun-smoke-<you>" -var="db_password=..."
#
# cluster_name and db_password are deliberately not set here — pick a unique
# cluster_name per run and never commit a real db_password to a tracked file.

# Required by variables.tf but unused: create_route53_zone is false below, so
# this value is never read. Placeholder only — no real domain needed.
base_domain = "smoke-test.invalid"

# One node is enough to prove the cluster comes up and schedules the EKS
# system add-ons (VPC CNI, kube-proxy, coredns) — this is not sized to run
# real workloads.
node_instance_types = ["t3.small"]
node_min_size       = 1
node_max_size       = 2
node_desired_size   = 1

# Single NAT gateway is already the default (ha_nat_gateway = false); kept
# explicit here so this file is a complete picture of the smoke-test shape.
ha_nat_gateway = false

# CRITICAL: the variables.tf default is `true`, which makes `terraform
# destroy` refuse to delete the RDS instance — the #1 way a "cheap" smoke
# test turns into an orphaned ~$25-35/month RDS bill nobody notices.
rds_deletion_protection = false

# No real DNS to manage for a smoke test — skip creating a Route53 zone
# (avoids both the zone and needing a real domain you control).
create_route53_zone = false

# No service images to push for a smoke test.
ecr_repositories = []
