# Site definitions (hostnames per service) live in terraform.tfvars as
# var.sites: the repo describes the shape of a site, never anybody's actual
# domains. Composing them from the service repositories' own terraform was
# considered and dropped - a public root cannot init private git modules, and
# the indirection bought little.
# The concrete hostnames live in terraform.tfvars (var.sites), so the repo
# describes the shape of a site rather than anybody's actual domains.


# The applim pods read their secrets from an env Secret the deploy references as
# optional. The values live in terraform.tfvars (gitignored), so the key is typed
# once there rather than into kubectl. The namespace is created by the app's own
# deploy workflow, so deploy the app once before the first apply of this.
resource "kubernetes_secret_v1" "applim_env" {
  count = length(var.applim_env) > 0 ? 1 : 0

  metadata {
    name      = local.is_production ? "applim-env" : "applim-test-env"
    namespace = local.is_production ? "applim" : "applim-test"
  }

  data = var.applim_env
}
