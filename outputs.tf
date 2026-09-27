output "cluster_name" {
  description = "Full cluster name for this workspace (projects-dev, projects-production)."
  value       = local.full_cluster_name
}

output "kubeconfig" {
  description = "Admin (system:masters) kubeconfig for the operator only. It cannot be revoked, so it never goes into a repository: deploys use deployer_kubeconfigs."
  value       = module.cluster.kubeconfig
  sensitive   = true
}

output "configure_kubectl" {
  description = "PowerShell one-liner that writes the kubeconfig above to the user's .kube directory."
  value       = "terraform output -raw kubeconfig > $env:USERPROFILE/.kube/${local.full_cluster_name}.yaml"
}

output "kube_api_hostname" {
  description = "Access-gated tunnel hostname CI uses to reach the kube-API."
  value       = module.edge.kube_api_hostname
}

# Per-app deploy credentials: the source of each app repository's KUBE_CONFIG
# environment secret. Scoped to the app's namespace; revoke by replacing
# kubernetes_secret_v1.deployer_token["<app>"].
output "deployer_kubeconfigs" {
  description = "Namespaced deployer kubeconfig per site key (GitHub environment secret KUBE_CONFIG in that app's repository, base64-encoded)."
  value = {
    for app, token in kubernetes_secret_v1.deployer_token : app => yamlencode({
      apiVersion = "v1"
      kind       = "Config"
      clusters = [{
        name    = local.full_cluster_name
        cluster = { server = module.cluster.kubeconfig_data.host, "certificate-authority-data" = base64encode(token.data["ca.crt"]) }
      }]
      users = [{ name = "deployer", user = { token = token.data.token } }]
      contexts = [{
        name    = local.full_cluster_name
        context = { cluster = local.full_cluster_name, user = "deployer", namespace = token.metadata[0].namespace }
      }]
      "current-context" = local.full_cluster_name
    })
  }
  sensitive = true
}

# CI's Cloudflare Access credentials, one pair per consumer (infra, then each
# site key); piped into that repository's GitHub environment secrets.
output "ci_access_tokens" {
  description = "Access service token per consumer: { client_id, client_secret } for CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET."
  value       = module.edge.ci_access_tokens
  sensitive   = true
}
