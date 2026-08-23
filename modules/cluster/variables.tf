variable "hcloud_token" {
  description = "Hetzner Cloud API token with read/write access."
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Full cluster name, environment included (projects-dev, projects-production). Names every Hetzner object."
  type        = string
}

variable "ssh_public_key" {
  description = "Public key material for the cluster nodes' SSH key."
  type        = string
}

variable "ssh_private_key" {
  description = "Matching private key material; the module uses it to provision the nodes over SSH."
  type        = string
  sensitive   = true
}

variable "allow_scheduling_on_control_plane" {
  description = "Schedule workloads on the control plane too. True on dev, where the control plane is the only spare capacity."
  type        = bool
  default     = false
}

variable "enable_autoscaler" {
  description = "Add an autoscaled cx23 nodepool (0-2 nodes). Production only."
  type        = bool
  default     = false
}

variable "firewall_ssh_source" {
  description = "CIDRs allowed to reach node SSH."
  type        = list(string)
}

variable "firewall_kube_api_source" {
  description = "CIDRs allowed to reach the kube-API directly on 6443."
  type        = list(string)
}

variable "agent_count" {
  description = "Servers in the agent nodepool. Mind the Hetzner project server limit before raising it."
  type        = number
  default     = 1

  validation {
    condition     = var.agent_count >= 1 && var.agent_count <= 5
    error_message = "Between 1 and 5 agents; a single-node cluster opens klipper-lb ports and more than five outgrows the default project limit."
  }
}
