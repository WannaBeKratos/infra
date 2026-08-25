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

# The site and the sweeper are one pod today, sharing the feed database through the
# filesystem. Where they are not - two Deployments, one owning the file and serving it
# to the other - a cluster is not a boundary on its own: any pod can reach any Service.
# This is the token both sides carry, minted here so neither repository holds it and
# nobody has to type it. Without this Secret the feed API is not mapped at all and the
# app runs exactly as before, from the file.
resource "random_password" "applim_feed_api" {
  length  = 48
  special = false
}

resource "kubernetes_secret_v1" "applim_feed_api" {
  metadata {
    name      = local.is_production ? "applim-feed-api" : "applim-test-feed-api"
    namespace = local.is_production ? "applim" : "applim-test"
  }

  data = {
    APPLIM_FEED_API_TOKEN = random_password.applim_feed_api.result
  }
}
