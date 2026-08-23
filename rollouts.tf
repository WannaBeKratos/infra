# Argo Rollouts powers blue/green deployments: the Rollout in
# kubernetes/application.yaml serves the new version on a preview Service until
# auto-promotion flips the active one, and auto-aborts if its probes fail. No
# traffic router is needed — cloudflared routes to whichever Service is active.
resource "kubernetes_namespace_v1" "argo_rollouts" {
  metadata {
    name = "argo-rollouts"
  }
}

resource "helm_release" "argo_rollouts" {
  name       = "argo-rollouts"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-rollouts"
  version    = "2.41.1"
  namespace  = kubernetes_namespace_v1.argo_rollouts.metadata[0].name
  atomic     = true
  timeout    = 600
}
