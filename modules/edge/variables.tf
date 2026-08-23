variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the tunnel and the Access applications."
  type        = string
}

variable "cloudflare_zone_ids" {
  description = "Cloudflare zone name to zone ID, for the zones tunnel hostnames live in. Must include the operations_domain zone, which holds the kube-API hostname."
  type        = map(string)
}

variable "cluster_name" {
  description = "Full cluster name, environment included. Names the tunnel and every Access object."
  type        = string
}

variable "sites" {
  description = "Site definitions to route: production hostname, its aliases, and the dev test hostname. Keyed by service name, which is also its namespace and service name."
  type = map(object({
    production_hostname = string
    production_aliases  = list(string)
    test_hostname       = string
  }))
}

variable "is_production" {
  description = "Serve production hostnames and previews rather than the test hostnames."
  type        = bool
}

variable "enable_production_cutover" {
  description = "Publish production tunnel routes and DNS records. Ignored outside production."
  type        = bool
  default     = false
}

variable "preview_access_emails" {
  description = "Emails allowed through Cloudflare Access to preview and test hostnames (one-time PIN)."
  type        = list(string)
}

variable "operations_domain" {
  description = "Domain that carries the operational hostnames (kube-API et al.); must be a key of cloudflare_zone_ids."
  type        = string
}
