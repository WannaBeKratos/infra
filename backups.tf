# Litestream streams the feed database to R2. The bucket is per-workspace and the
# credential is minted here the same way bootstrap mints the state token: the S3
# access key is the token id and the secret is the SHA-256 of its value. The pod
# reads them from the -litestream Secret; without that Secret the containers idle
# and the app runs exactly as before.
resource "cloudflare_r2_bucket" "applim_feed" {
  account_id = var.cloudflare_account_id
  name       = "applim-feed-${local.environment}"
  location   = "WEUR"
}

resource "cloudflare_account_token" "applim_feed" {
  account_id = var.cloudflare_account_id
  name       = "applim-feed-${local.environment}"

  policies = [{
    effect = "allow"
    permission_groups = [{
      id = "6a018a9f2fc74eb6b293b0c548f38b39"
      }, {
      id = "2efd5506f9c8494dacb1fa10a3e7d5b6"
    }]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_default_${cloudflare_r2_bucket.applim_feed.name}" = "*"
    })
  }]

  # Rotate before this date: taint this resource and apply.
  expires_on = "2027-12-31T23:59:59Z"
}

resource "kubernetes_secret_v1" "applim_litestream" {
  metadata {
    name      = local.is_production ? "applim-litestream" : "applim-test-litestream"
    namespace = local.is_production ? "applim" : "applim-test"
  }

  data = {
    LITESTREAM_ACCESS_KEY_ID     = cloudflare_account_token.applim_feed.id
    LITESTREAM_SECRET_ACCESS_KEY = sha256(cloudflare_account_token.applim_feed.value)
    # Bucket and endpoint travel separately because litestream 0.3 ignores an
    # "?endpoint=" query on an s3:// URL and silently talks to AWS instead; the
    # containers assemble a config file from these.
    APPLIM_FEED_BUCKET   = cloudflare_r2_bucket.applim_feed.name
    APPLIM_FEED_ENDPOINT = "https://${var.cloudflare_account_id}.r2.cloudflarestorage.com"
  }
}
