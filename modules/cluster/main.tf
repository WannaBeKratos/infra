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
  # v3.1.0, pinned by commit: a registry version resolves to a git tag, which
  # upstream can move, and this module holds the hcloud token and node root.
  # Any bump of this module can rebuild nodes.
  source = "git::https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner.git?ref=ed524efe85377a62f1aecf34422c8ab1b073a75b"

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
      destination_ips = local.cloudflare_tunnel_ips
    },
    {
      description     = "Cloudflare Tunnel egress (fallback)"
      direction       = "out"
      protocol        = "tcp"
      port            = "7844"
      source_ips      = []
      destination_ips = local.cloudflare_tunnel_ips
    }
  ]

  # Cloudflare Tunnel terminates TLS at the edge; no ingress controller or cert-manager.
  ingress_controller  = "none"
  enable_cert_manager = false

  # No Hetzner load balancers: a LoadBalancer Service would put a public IP in
  # front of the pods and route around Cloudflare's WAF and Access entirely.
  hetzner_ccm_merge_values = yamlencode({
    env = { HCLOUD_LOAD_BALANCERS_ENABLED = { value = "false" } }
  })
}

# region1/region2.v2.argotunnel.com, as published for tunnel firewalls:
# https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/
locals {
  cloudflare_tunnel_ips = ["198.41.192.0/24", "198.41.200.0/24", "2606:4700:a0::/48", "2606:4700:a8::/48"]
}
