# The cluster itself: nodes, network, firewall. Highest blast radius in the
# repo, so it sits behind its own module boundary and its own plan; platform
# and application changes never have to touch it.
terraform {
  required_providers {
    hcloud = {
      source = "hetznercloud/hcloud"
    }
  }
}

module "kube" {
  source = "kube-hetzner/kube-hetzner/hcloud"
  # Exact pin: a minor bump of this module rebuilds nodes.
  version = "3.1.0"

  providers = {
    hcloud = hcloud
  }

  hcloud_token    = var.hcloud_token
  cluster_name    = var.cluster_name
  network_region  = "eu-central"
  ssh_public_key  = var.ssh_public_key
  ssh_private_key = var.ssh_private_key

  control_plane_nodepools = [
    {
      name        = "control-plane"
      server_type = "cx23"
      location    = "nbg1"
      labels      = []
      taints      = []
      count       = 1
    }
  ]

  allow_scheduling_on_control_plane = var.allow_scheduling_on_control_plane

  # Always at least one agent: a single-node cluster makes the module open
  # ports 80/443 to the world for klipper-lb, which the tunnel never needs.
  agent_nodepools = [
    {
      name        = "agent"
      server_type = "cx23"
      location    = "nbg1"
      labels      = []
      taints      = []
      count       = var.agent_count
    }
  ]

  autoscaler_nodepools = var.enable_autoscaler ? [
    {
      name        = "autoscaled"
      server_type = "cx23"
      location    = "nbg1"
      min_nodes   = 0
      max_nodes   = 2
    }
  ] : []

  # Hetzner firewall: module default-denies inbound; nothing public is needed
  # at all since ingress is an outbound-only Cloudflare Tunnel.
  firewall_ssh_source = var.firewall_ssh_source
  # CI reaches the kube-API through the Access-gated tunnel route; only the
  # operator's own terraform/kubectl connect to 6443 directly.
  firewall_kube_api_source = var.firewall_kube_api_source

  # cloudflared reaches Cloudflare's edge over QUIC on UDP 7844 (TCP fallback).
  extra_firewall_rules = [
    {
      description     = "Cloudflare Tunnel egress (QUIC)"
      direction       = "out"
      protocol        = "udp"
      port            = "7844"
      source_ips      = []
      destination_ips = ["0.0.0.0/0", "::/0"]
    },
    {
      description     = "Cloudflare Tunnel egress (fallback)"
      direction       = "out"
      protocol        = "tcp"
      port            = "7844"
      source_ips      = []
      destination_ips = ["0.0.0.0/0", "::/0"]
    }
  ]

  # Cloudflare Tunnel terminates TLS at the edge; no ingress controller or cert-manager.
  ingress_controller  = "none"
  enable_cert_manager = false
}
