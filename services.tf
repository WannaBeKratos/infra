# Site definitions (hostnames per service) live in terraform.tfvars as
# var.sites: the repo describes the shape of a site, never anybody's actual
# domains. Composing them from the service repositories' own terraform was
# considered and dropped - a public root cannot init private git modules, and
# the indirection bought little.
# The concrete hostnames live in terraform.tfvars (var.sites), so the repo
# describes the shape of a site rather than anybody's actual domains.

# Each app's namespace is owned here, not by its deploy workflow, so the app
# repository only ever holds a deployer confined to it - never cluster-admin.
# The key is the site key; dev appends -test, as the deploy workflow does.
resource "kubernetes_namespace_v1" "app" {
  for_each = var.sites

  metadata {
    name = local.is_production ? each.key : "${each.key}-test"
    labels = {
      # ponytail: baseline is enforced and restricted only warned and audited,
      # because each app deploys its own copy of the manifest; enforce
      # restricted once every app's copy passes it.
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
    }
  }
}

resource "kubernetes_service_account_v1" "deployer" {
  for_each = kubernetes_namespace_v1.app

  metadata {
    name      = "deployer"
    namespace = each.value.metadata[0].name
  }
}

# Exactly what deploy-application.yml does: apply the Services, the Rollout and
# the registry pull Secret, then watch the rollout. An app whose own manifest
# adds other kinds adds them here.
resource "kubernetes_role_v1" "deployer" {
  for_each = kubernetes_namespace_v1.app

  metadata {
    name      = "deployer"
    namespace = each.value.metadata[0].name
  }

  rule {
    api_groups = ["", "argoproj.io"]
    resources  = ["services", "secrets", "rollouts"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }

  rule {
    api_groups = ["", "apps", "argoproj.io"]
    resources  = ["pods", "replicasets", "analysisruns", "experiments"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "deployer" {
  for_each = kubernetes_namespace_v1.app

  metadata {
    name      = "deployer"
    namespace = each.value.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.deployer[each.key].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.deployer[each.key].metadata[0].name
    namespace = each.value.metadata[0].name
  }
}

# Long-lived but revocable: replace this Secret and the old token dies.
resource "kubernetes_secret_v1" "deployer_token" {
  for_each = kubernetes_namespace_v1.app

  metadata {
    name        = "deployer-token"
    namespace   = each.value.metadata[0].name
    annotations = { "kubernetes.io/service-account.name" = kubernetes_service_account_v1.deployer[each.key].metadata[0].name }
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# Cloudflare Access only exists at the edge. Inside the cluster an app answers
# the tunnel and its own pods, nobody else - so a compromised pod elsewhere
# cannot reach it (or its unreleased preview) without Access in the way.
resource "kubernetes_network_policy_v1" "app" {
  for_each = kubernetes_namespace_v1.app

  metadata {
    name      = "from-tunnel-and-self"
    namespace = each.value.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "cloudflared" }
        }
      }
      from {
        pod_selector {}
      }
    }
  }
}

# The applim pods read their secrets from an env Secret the deploy references as
# optional. The values live in terraform.tfvars (gitignored), so the key is typed
# once there rather than into kubectl.
resource "kubernetes_secret_v1" "applim_env" {
  count = length(var.applim_env) > 0 ? 1 : 0

  metadata {
    name      = local.is_production ? "applim-env" : "applim-test-env"
    namespace = kubernetes_namespace_v1.app["applim"].metadata[0].name
  }

  data = var.applim_env
}
