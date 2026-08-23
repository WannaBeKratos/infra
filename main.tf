# k3s clusters on Hetzner Cloud via kube-hetzner, one per Terraform workspace:
#   terraform workspace new dev         -> projects-dev (serves test.* hostnames)
#   terraform workspace new production  -> projects-production
# Requires a one-time MicroOS snapshot build with Packer; see README.
locals {
  environment       = terraform.workspace == "default" ? "production" : terraform.workspace
  is_production     = local.environment == "production"
  full_cluster_name = "${var.cluster_name}-${local.environment}"
}

module "cluster" {
  source = "./modules/cluster"

  providers = {
    hcloud = hcloud
  }

  hcloud_token = var.hcloud_token
  cluster_name = local.full_cluster_name
  # Production uses its own keypair (<private_key_path>_prod): Hetzner rejects
  # the same key material twice in one project, and per-env keys isolate access.
  ssh_public_key  = file(pathexpand(local.is_production ? "${var.ssh_private_key_path}_prod.pub" : var.ssh_public_key_path))
  ssh_private_key = file(pathexpand(local.is_production ? "${var.ssh_private_key_path}_prod" : var.ssh_private_key_path))

  # Dev also schedules on the control plane for extra capacity; only production
  # gets an autoscaled nodepool.
  allow_scheduling_on_control_plane = !local.is_production
  enable_autoscaler                 = local.is_production

  agent_count = lookup(var.agent_counts, local.environment, 1)

  firewall_ssh_source      = var.firewall_ssh_source
  firewall_kube_api_source = var.firewall_kube_api_source
}

module "edge" {
  source = "./modules/edge"

  cloudflare_account_id     = var.cloudflare_account_id
  cloudflare_zone_ids       = var.cloudflare_zone_ids
  cluster_name              = local.full_cluster_name
  sites                     = var.sites
  is_production             = local.is_production
  enable_production_cutover = var.enable_production_cutover
  preview_access_emails     = var.preview_access_emails
  operations_domain         = var.operations_domain
}
