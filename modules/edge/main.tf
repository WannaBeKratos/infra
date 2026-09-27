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

# CI authenticates to the kube-API hostname with a service token; the Access
# application rejects every other client at the edge. One token per consumer
# (this repository's CI, then each app repository by site key), so a leaked
# pair is revoked on its own and the Access log says who connected.
resource "cloudflare_zero_trust_access_service_token" "ci" {
  for_each   = toset(concat(["infra"], keys(var.sites)))
  account_id = var.cloudflare_account_id
  name       = "${var.cluster_name}-ci-${each.key}"
  duration   = "8760h"
}

# The single shared token becomes infra's; rotate it once the app repositories
# carry their own (docs/OPERATIONS.md, "Migrate to the hardened setup").
moved {
  from = cloudflare_zero_trust_access_service_token.ci
  to   = cloudflare_zero_trust_access_service_token.ci["infra"]
}

resource "cloudflare_zero_trust_access_policy" "kube_api_ci" {
  account_id = var.cloudflare_account_id
  name       = "${var.cluster_name}-kube-api-ci"
  decision   = "non_identity"
  include = [
    for token in cloudflare_zero_trust_access_service_token.ci : { service_token = { token_id = token.id } }
  ]
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
        automount_service_account_token = false

        security_context {
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name = "cloudflared"
          # Tag for people, digest for the kubelet: this pod holds the tunnel
          # token. Keep the CI download in .github/workflows/*.yml on the same version.
          image             = "cloudflare/cloudflared:2026.9.3@sha256:072c067d25ccbe61d46e18f0d0723255f2bb5304f7317caa95b27031520ff92c"
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

# Nothing dials in to cloudflared; its metrics port only answers the kubelet's
# probes, which come from the node itself and are not subject to the policy.
resource "kubernetes_network_policy_v1" "cloudflared" {
  metadata {
    name      = "deny-ingress"
    namespace = kubernetes_namespace_v1.cloudflared.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

# claude.ai's connector servers must reach the MCP endpoint and its OAuth
# machinery, and they cannot answer an Access challenge. The application
# authenticates these paths itself (workspace token or OAuth grant), so Access
# steps aside for them, from Anthropic's published outbound range only; anyone
# else (the operator's browser on the OAuth consent page) gets the e-mail PIN.
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
  include    = [for cidr in var.mcp_client_cidrs : { ip = { ip = cidr } }]
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
    }, {
    id         = cloudflare_zero_trust_access_policy.preview_operator[0].id
    precedence = 2
  }]
}

# Zone-wide edge rules. The zones are shared by both workspaces and each of
# these is a per-zone singleton, so only the production workspace owns them.
locals {
  zone_rule_zones = var.is_production ? var.cloudflare_zone_ids : {}
}

# Access and the WAF match the normalized URL; forward that same URL to the
# origin, so an encoded path cannot match one rule at the edge and route
# somewhere else in the app.
resource "cloudflare_url_normalization_settings" "zone" {
  for_each = local.zone_rule_zones
  zone_id  = each.value
  scope    = "both"
  type     = "cloudflare"
}

# The OAuth endpoints answer the internet without Access, so guessing codes or
# spamming client registration is throttled per IP. /mcp is left out on
# purpose: every Claude user reaches it from Anthropic's few egress IPs, and the
# Free plan cannot exempt a source range.
resource "cloudflare_ruleset" "rate_limit" {
  for_each = local.zone_rule_zones
  zone_id  = each.value
  name     = "rate-limit"
  kind     = "zone"
  phase    = "http_ratelimit"
  rules = [{
    description = "Throttle OAuth endpoints"
    action      = "block"
    expression  = "starts_with(http.request.uri.path, \"/oauth\")"
    ratelimit = {
      characteristics     = ["ip.src", "cf.colo.id"]
      period              = 10
      requests_per_period = 20
      mitigation_timeout  = 10
    }
  }]
}

resource "cloudflare_zone_setting" "min_tls_version" {
  for_each   = local.zone_rule_zones
  zone_id    = each.value
  setting_id = "min_tls_version"
  value      = "1.2"
}

resource "cloudflare_zone_setting" "always_use_https" {
  for_each   = local.zone_rule_zones
  zone_id    = each.value
  setting_id = "always_use_https"
  value      = "on"
}
