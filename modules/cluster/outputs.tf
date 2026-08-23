output "cluster_name" {
  description = "Full cluster name this module deployed."
  value       = var.cluster_name
}

output "kubeconfig" {
  description = "Admin kubeconfig for the cluster, as a YAML document."
  value       = module.kube.kubeconfig
  sensitive   = true
}

output "kubeconfig_data" {
  description = "Kubeconfig split into host and client/CA certificates, for provider configuration."
  value       = module.kube.kubeconfig_data
  sensitive   = true
}
