# Cloudflare Tunnel replaces the in-cluster reverse proxy: cloudflared makes an
# outbound-only connection to Cloudflare's edge, which terminates TLS and routes
# each hostname to a cluster service. No load balancer, no open inbound ports,
# no ACME management.
#
# Everything here is edge-side plus the one pod that dials out to it, so it
# changes on every routing or hostname change without ever touching the nodes.
terraform {
  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
    }
  }
}

locals {
  # dev cluster serves the test hostnames; production serves the real ones once
  # enable_production_cutover is set.
  tunnel_routes = var.is_production ? (var.enable_production_cutover ? flatten([
    for name, site in var.sites : concat(
      [{ hostname = site.production_hostname, upstream = "${name}.${name}.svc.cluster.local:80" }],
      # ponytail: aliases serve the same content instead of redirecting; add a
      # Cloudflare redirect rule when a canonical URL matters for SEO.
      [for alias in site.production_aliases : { hostname = alias, upstream = "${name}.${name}.svc.cluster.local:80" }]
    )
    ]) : []) : [
    for name, site in var.sites : {
      hostname = site.test_hostname
      upstream = "${name}-test.${name}-test.svc.cluster.local:80"
    }
  ]

  # The kube-API rides the same tunnel as a TCP service, gated by Cloudflare
  # Access; the Hetzner firewall keeps port 6443 closed to everyone else.
  kube_api_hostname = "${var.is_production ? "k8s" : "k8s-dev"}.${var.operations_domain}"

  # Blue/green previews: production only. The not-yet-promoted version serves
  # on preview.<hostname>, gated by Cloudflare Access (operator email OTP).
  preview_routes = var.is_production ? {
    for name, site in var.sites :
    "preview.${site.production_hostname}" => "${name}-preview.${name}.svc.cluster.local:80"
  } : {}

  # Operator-only hostnames: production previews, and every dev test site.
  access_protected_hostnames = var.is_production ? keys(local.preview_routes) : [
    for route in local.tunnel_routes : route.hostname
  ]

  # Map each public hostname to the Cloudflare zone that contains it.
  tunnel_record_zone = merge(
    {
      for route in local.tunnel_routes :
      route.hostname => [for zone, id in var.cloudflare_zone_ids : id if endswith(route.hostname, zone)][0]
    },
    {
      for hostname, upstream in local.preview_routes :
      hostname => [for zone, id in var.cloudflare_zone_ids : id if endswith(hostname, zone)][0]
    },
    { (local.kube_api_hostname) = var.cloudflare_zone_ids[var.operations_domain] },
  )
}

# The zone lookup above indexes the first match, so a hostname in a zone that is
# missing from cloudflare_zone_ids would fail deep inside a for expression.
check "hostnames_have_zones" {
  assert {
    condition = alltrue([
      for hostname in concat([for route in local.tunnel_routes : route.hostname], keys(local.preview_routes)) :
      anytrue([for zone in keys(var.cloudflare_zone_ids) : endswith(hostname, zone)])
    ])
    error_message = "Every tunnel and preview hostname must end with a zone listed in cloudflare_zone_ids. Add the missing zone name to zone ID mapping."
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "cluster" {
  account_id = var.cloudflare_account_id
  name       = var.cluster_name
  config_src = "cloudflare"
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "cluster" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.cluster.id
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "cluster" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.cluster.id

  config = {
    ingress = concat(
      [for route in local.tunnel_routes : {
        hostname = route.hostname
        service  = "http://${route.upstream}"
      }],
      [for hostname, upstream in local.preview_routes : {
        hostname = hostname
        service  = "http://${upstream}"
      }],
      [{
        hostname = local.kube_api_hostname
        service  = "tcp://kubernetes.default.svc:443"
      }],
      [{ service = "http_status:404" }]
    )
  }
}

resource "cloudflare_dns_record" "tunnel" {
  for_each = local.tunnel_record_zone

  zone_id = each.value
  name    = each.key
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.cluster.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

# CI authenticates to the kube-API hostname with this service token; the
# Access application rejects every other client at the edge.
resource "cloudflare_zero_trust_access_service_token" "ci" {
  account_id = var.cloudflare_account_id
  name       = "${var.cluster_name}-ci"
}

resource "cloudflare_zero_trust_access_policy" "kube_api_ci" {
  account_id = var.cloudflare_account_id
  name       = "${var.cluster_name}-kube-api-ci"
  decision   = "non_identity"
  include = [{
    service_token = { token_id = cloudflare_zero_trust_access_service_token.ci.id }
  }]
}

resource "cloudflare_zero_trust_access_application" "kube_api" {
  account_id = var.cloudflare_account_id
  name       = "${var.cluster_name}-kube-api"
  domain     = local.kube_api_hostname
  type       = "self_hosted"
  policies = [{
    id         = cloudflare_zero_trust_access_policy.kube_api_ci.id
    precedence = 1
  }]
}

# Preview and test pages let the operator in with an emailed one-time PIN.
resource "cloudflare_zero_trust_access_policy" "preview_operator" {
  count      = length(local.access_protected_hostnames) > 0 ? 1 : 0
  account_id = var.cloudflare_account_id
  name       = "${var.cluster_name}-preview-operator"
  decision   = "allow"
  include = [
    for email in var.preview_access_emails : { email = { email = email } }
  ]
}

resource "cloudflare_zero_trust_access_application" "preview" {
  for_each   = toset(local.access_protected_hostnames)
  account_id = var.cloudflare_account_id
  name       = "${var.cluster_name}-${each.key}"
  domain     = each.key
  type       = "self_hosted"
  policies = [{
    id         = cloudflare_zero_trust_access_policy.preview_operator[0].id
    precedence = 1
  }]
}

resource "kubernetes_namespace_v1" "cloudflared" {
  metadata {
    name = "cloudflared"
  }
}

resource "kubernetes_secret_v1" "tunnel_token" {
  metadata {
    name      = "tunnel-token"
    namespace = kubernetes_namespace_v1.cloudflared.metadata[0].name
  }

  data = {
    token = data.cloudflare_zero_trust_tunnel_cloudflared_token.cluster.token
  }
}

resource "kubernetes_deployment_v1" "cloudflared" {
  metadata {
    name      = "cloudflared"
    namespace = kubernetes_namespace_v1.cloudflared.metadata[0].name
    labels = {
      app = "cloudflared"
    }
  }

  spec {
    # ponytail: one replica; bump to 2 if tunnel restarts ever drop traffic.
    replicas = 1

    selector {
      match_labels = {
        app = "cloudflared"
      }
    }

    template {
      metadata {
        labels = {
          app = "cloudflared"
        }
      }

      spec {
        security_context {
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name              = "cloudflared"
          image             = "cloudflare/cloudflared:2025.8.1"
          image_pull_policy = "Always"
          args              = ["tunnel", "--no-autoupdate", "--metrics", "0.0.0.0:2000", "run"]

          env {
            name = "TUNNEL_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.tunnel_token.metadata[0].name
                key  = "token"
              }
            }
          }

          port {
            name           = "metrics"
            container_port = 2000
          }

          resources {
            requests = {
              cpu    = "20m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }

          security_context {
            run_as_non_root            = true
            run_as_user                = 65532
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = "metrics"
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/ready"
              port = "metrics"
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }
        }
      }
    }
  }
}

# claude.ai's connector servers must reach the MCP endpoint and its OAuth
# machinery, and they cannot answer an Access challenge. The application
# authenticates these paths itself (workspace token or OAuth grant), so Access
# steps aside for exactly them while the rest of each test site stays gated.
# Production hostnames carry no Access at all, so this only exists off-production.
locals {
  mcp_open_paths = var.is_production ? [] : [
    for path in [
      "/mcp",
      "/oauth",
      "/.well-known/oauth-authorization-server",
      "/.well-known/oauth-protected-resource",
    ] : "${var.sites["applim"].test_hostname}${path}"
  ]
}

resource "cloudflare_zero_trust_access_policy" "mcp_bypass" {
  count      = length(local.mcp_open_paths) > 0 ? 1 : 0
  account_id = var.cloudflare_account_id
  name       = "${var.cluster_name}-mcp-bypass"
  decision   = "bypass"
  include    = [{ everyone = {} }]
}

resource "cloudflare_zero_trust_access_application" "mcp" {
  for_each   = toset(local.mcp_open_paths)
  account_id = var.cloudflare_account_id
  name       = "${var.cluster_name}-${each.key}"
  domain     = each.key
  type       = "self_hosted"
  policies = [{
    id         = cloudflare_zero_trust_access_policy.mcp_bypass[0].id
    precedence = 1
  }]
}
