terraform {
  # Upper bound so a future Terraform 2.x cannot silently become the CI runner's
  # version; CI pins the exact patch (see .github/workflows/terraform.yml).
  required_version = ">= 1.10.0, < 2.0.0"

  # Remote state in Cloudflare R2 (S3-compatible). Workspace states land under
  # env/<workspace>/infra.tfstate. Credentials come from backend.hcl (gitignored):
  #   terraform init -backend-config=backend.hcl
  backend "s3" {
    bucket = "projects-terraform-state"
    key    = "infra.tfstate"
    region = "auto"
    endpoints = {
      s3 = "https://b6e08ea226424651e45ce07fd2a244ee.r2.cloudflarestorage.com"
    }
    # R2 supports conditional writes, which native S3 locking uses.
    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.51"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

provider "kubernetes" {
  # CI reaches the kube-API through a cloudflared TCP proxy on localhost (the
  # k3s certificate includes 127.0.0.1), so it overrides the host; everywhere
  # else the cluster's own address is used.
  host                   = var.kube_api_url != null ? var.kube_api_url : module.cluster.kubeconfig_data.host
  client_certificate     = module.cluster.kubeconfig_data.client_certificate
  client_key             = module.cluster.kubeconfig_data.client_key
  cluster_ca_certificate = module.cluster.kubeconfig_data.cluster_ca_certificate
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "helm" {
  kubernetes = {
    host                   = module.cluster.kubeconfig_data.host
    client_certificate     = module.cluster.kubeconfig_data.client_certificate
    client_key             = module.cluster.kubeconfig_data.client_key
    cluster_ca_certificate = module.cluster.kubeconfig_data.cluster_ca_certificate
  }
}
