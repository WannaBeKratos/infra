variable "hcloud_token" {
  description = "Hetzner Cloud API token with read/write access. Prefer TF_VAR_hcloud_token over a tfvars file."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Account:Cloudflare Tunnel:Edit plus Zone:Read and DNS:Edit for the configured zones."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (dashboard home -> account id)."
  type        = string
}

variable "cluster_name" {
  description = "Base cluster name; the workspace-derived environment is appended (projects-dev, projects-production)."
  type        = string
  default     = "projects"

  # Ends up in Hetzner server/network names and Cloudflare Access app names.
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric with internal hyphens."
  }
}

variable "ssh_public_key_path" {
  description = "Path to the passphrase-less SSH public key used for cluster nodes."
  type        = string
  default     = "~/.ssh/hetzner_kube.pub"
}

variable "ssh_private_key_path" {
  description = "Path to the passphrase-less SSH private key used for cluster nodes."
  type        = string
  default     = "~/.ssh/hetzner_kube"
}

variable "cloudflare_zone_ids" {
  description = "Cloudflare zone name to zone ID, for the zones tunnel hostnames live in."
  type        = map(string)

  # modules/edge indexes this zone directly for the kube-API record.
  validation {
    condition     = length(var.cloudflare_zone_ids) > 0
    error_message = "cloudflare_zone_ids must name at least the zone that holds the operations_domain."
  }
}

variable "firewall_ssh_source" {
  description = "CIDRs allowed to reach node SSH. No default on purpose: it is the operator's own address, so it lives in terraform.tfvars (never in git). Change it and the TERRAFORM_TFVARS GitHub secret has to be refreshed too."
  type        = list(string)

  validation {
    condition     = alltrue([for c in var.firewall_ssh_source : can(cidrhost(c, 0))])
    error_message = "firewall_ssh_source entries must be valid IPv4/IPv6 CIDRs."
  }
}

variable "firewall_kube_api_source" {
  description = "CIDRs allowed to reach the kube-API directly on 6443. CI uses the Cloudflare Access tunnel route instead. Same story as firewall_ssh_source: operator address, terraform.tfvars only."
  type        = list(string)

  validation {
    condition     = alltrue([for c in var.firewall_kube_api_source : can(cidrhost(c, 0))])
    error_message = "firewall_kube_api_source entries must be valid IPv4/IPv6 CIDRs."
  }
}

variable "preview_access_emails" {
  description = "Emails allowed through Cloudflare Access to preview and test hostnames (one-time PIN). Personal addresses, so they live in terraform.tfvars, not here; refresh the TERRAFORM_TFVARS GitHub secret after changing them. Empty only ever plans — Cloudflare rejects an Access policy with no principals."
  type        = list(string)
  default     = []
}

variable "enable_production_cutover" {
  description = "Publish production tunnel routes and DNS records. Leave false until test deployments are healthy."
  type        = bool
  default     = false
}

variable "applim_env" {
  description = "Environment for the applim pods (e.g. Skills__Model__ApiKey). Set it in terraform.tfvars, which never enters git."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "kube_api_url" {
  description = "Override for the kube-API address. CI sets https://127.0.0.1:6443 and fronts it with a cloudflared TCP proxy; leave null everywhere else."
  type        = string
  default     = null
}

variable "agent_counts" {
  description = "Agent servers per environment. Five servers total is the default Hetzner project limit; ask Hetzner to raise it before the autoscaler needs headroom."
  type        = map(number)
  default = {
    dev        = 1
    production = 2
  }
}

variable "operations_domain" {
  description = "Domain carrying operational hostnames such as the kube-API. Must be a key of cloudflare_zone_ids. Set in terraform.tfvars."
  type        = string
}

variable "sites" {
  description = "Site definitions per service: hostnames for production, aliases and test. Set in terraform.tfvars; see terraform.tfvars.example."
  type = map(object({
    production_hostname = string
    production_aliases  = list(string)
    test_hostname       = string
  }))
}
