output "cluster_name" {
  description = "Full cluster name for this workspace (projects-dev, projects-production)."
  value       = local.full_cluster_name
}

output "kubeconfig" {
  description = "Admin kubeconfig for the cluster. Also the source of the KUBE_CONFIG environment secret."
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

# CI's Cloudflare Access credentials; piped into GitHub environment secrets.
output "ci_access_client_id" {
  description = "Cloudflare Access service token ID for CI (GitHub secret CF_ACCESS_CLIENT_ID)."
  value       = module.edge.ci_access_client_id
  sensitive   = true
}

output "ci_access_client_secret" {
  description = "Cloudflare Access service token secret for CI (GitHub secret CF_ACCESS_CLIENT_SECRET)."
  value       = module.edge.ci_access_client_secret
  sensitive   = true
}
