output "kube_api_hostname" {
  description = "Access-gated tunnel hostname CI uses to reach the kube-API."
  value       = local.kube_api_hostname
}

output "ci_access_client_id" {
  description = "Cloudflare Access service token ID for CI (GitHub secret CF_ACCESS_CLIENT_ID)."
  value       = cloudflare_zero_trust_access_service_token.ci.client_id
  sensitive   = true
}

output "ci_access_client_secret" {
  description = "Cloudflare Access service token secret for CI (GitHub secret CF_ACCESS_CLIENT_SECRET)."
  value       = cloudflare_zero_trust_access_service_token.ci.client_secret
  sensitive   = true
}
