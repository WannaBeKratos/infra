output "kube_api_hostname" {
  description = "Access-gated tunnel hostname CI uses to reach the kube-API."
  value       = local.kube_api_hostname
}

output "ci_access_tokens" {
  description = "Cloudflare Access service token per consumer (infra, then each site key): the CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET pair for that repository."
  value = {
    for consumer, token in cloudflare_zero_trust_access_service_token.ci :
    consumer => { client_id = token.client_id, client_secret = token.client_secret }
  }
  sensitive = true
}
