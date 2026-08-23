# Bootstrap for the R2 state backend: the bucket and its scoped API token.
# Chicken-and-egg with the main config's backend, so state here stays local
# (gitignored; contains the token secret). Run once:
#   terraform -chdir=bootstrap init
#   terraform -chdir=bootstrap apply -var-file=../terraform.tfvars
# Writes ../backend.hcl with the derived S3 credentials.
#
# The provider token needs Account > Workers R2 Storage:Edit and
# Account > Account API Tokens:Edit on top of the main config's permissions.

terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token; needs Workers R2 Storage:Edit and Account API Tokens:Edit on top of the root config's permissions."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the R2 bucket and the scoped state token."
  type        = string
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

resource "cloudflare_r2_bucket" "state" {
  account_id = var.cloudflare_account_id
  name       = "projects-terraform-state"
  location   = "WEUR"
}

resource "cloudflare_account_token" "state" {
  account_id = var.cloudflare_account_id
  name       = "projects-terraform-state"

  policies = [{
    effect = "allow"
    permission_groups = [{
      id = "6a018a9f2fc74eb6b293b0c548f38b39"
      }, {
      id = "2efd5506f9c8494dacb1fa10a3e7d5b6"
    }]
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.cloudflare_account_id}_default_${cloudflare_r2_bucket.state.name}" = "*"
    })
  }]

  expires_on = "2027-08-21T23:59:59Z"
}

# R2's S3 API: access key = token ID, secret key = SHA-256 of the token value.
resource "local_sensitive_file" "backend" {
  filename        = "${path.module}/../backend.hcl"
  file_permission = "0600"
  content         = <<-EOT
    access_key = "${cloudflare_account_token.state.id}"
    secret_key = "${sha256(cloudflare_account_token.state.value)}"
  EOT
}
