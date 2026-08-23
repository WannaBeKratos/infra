# Operating the platform

The hands-on manual: first-time setup, the secrets model and the runbooks.
The README stays the map; this is the glovebox booklet.

## Quickstart for a fresh operator

### 1. One-time prerequisites

1. A Hetzner Cloud project and a read/write API token.
2. Two passphrase-less SSH keypairs — Hetzner rejects the same key material
   twice in one project, and per-environment keys isolate access:

   ```bash
   ssh-keygen -t ed25519 -N "" -f ~/.ssh/hetzner_kube
   ssh-keygen -t ed25519 -N "" -f ~/.ssh/hetzner_kube_prod
   ```

3. A MicroOS snapshot in the Hetzner project (Packer ≥ 1.16, once per project):

   ```bash
   export HCLOUD_TOKEN="$TF_VAR_hcloud_token"
   curl -LO https://raw.githubusercontent.com/kube-hetzner/terraform-hcloud-kube-hetzner/master/packer-template/hcloud-microos-snapshots.pkr.hcl
   packer init hcloud-microos-snapshots.pkr.hcl
   packer build hcloud-microos-snapshots.pkr.hcl
   ```

4. A Cloudflare API token with `Account > Cloudflare Tunnel:Edit`,
   `Account > Workers R2 Storage:Edit`, `Account > Account API Tokens:Edit`, and
   `Zone:Read` + `DNS:Edit` on every zone that holds a hostname.
5. A GitHub fine-grained PAT with `read:packages`, for the in-cluster image pull
   secret. The workflow's own `GITHUB_TOKEN` expires and cannot serve as one.
6. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill it in: account
   ID, zone IDs, your own CIDR for the two firewall variables, and the e-mail
   addresses Access should let through. This file never enters git.

### 2. Bootstrap the state backend

Chicken-and-egg: the R2 bucket that holds the state has to exist before the
backend can be configured, so `bootstrap/` keeps its own local state. Run it
once. It creates the bucket, mints a scoped token and writes `backend.hcl`.

```bash
export TF_VAR_cloudflare_api_token="..."
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply -var-file=../terraform.tfvars
```

State locking uses R2's conditional writes (`use_lockfile`).
`backend.hcl.example` documents the manual fallback if you ever mint the token
by hand.

### 3. Plan and apply, from WSL

Applies are manual by policy. They run from WSL so the providers are
`linux_amd64`; `TF_DATA_DIR=.terraform-linux` keeps that plugin cache separate
from the `windows_amd64` one in `.terraform/`, so the same checkout serves both
shells without re-initialising on every switch.

```bash
export TF_DATA_DIR=.terraform-linux
export TF_VAR_hcloud_token="..."
export TF_VAR_cloudflare_api_token="..."

terraform init -backend-config=backend.hcl
terraform workspace new dev          # `select` on later runs
terraform plan -out=tfplan
terraform apply tfplan
```

Repeat for `production` (`terraform workspace new production`). Then write the
kubeconfig and check the cluster:

```bash
terraform output -raw kubeconfig > ~/.kube/projects-dev.yaml
kubectl --kubeconfig ~/.kube/projects-dev.yaml get nodes
kubectl --kubeconfig ~/.kube/projects-dev.yaml -n cloudflared get pods
```

Production hostnames stay unpublished until you set
`enable_production_cutover = true` and apply the `production` workspace. Until
then only the tunnel, the cluster and the `test.*` routes exist.

## The secrets model

Three places, and they never overlap.

### Local only — never in git

`.gitignore` enforces all of these:

| File | Holds |
|---|---|
| `terraform.tfvars` | account and zone IDs, your firewall CIDRs, Access e-mails, `applim_env` values |
| `backend.hcl` | the R2 access key and secret for the state bucket |
| `bootstrap/terraform.tfstate` | the R2 state token in clear — the one state file that is not remote |
| `*_kubeconfig.yaml`, `~/.kube/*` | cluster admin credentials |
| `~/.ssh/hetzner_kube{,_prod}` | node SSH keys |
| `tfplan`, `apply-*.log`, `.terraform/`, `.terraform-linux/` | plan and provider artefacts, which contain resolved values |

Terraform state contains cluster credentials. Treat the R2 bucket as a secret
store, not as a build artefact.

### GitHub — this repository

Set from WSL with the workspace selected, because the Access tokens are
per-cluster outputs:

```bash
gh secret set BACKEND_HCL       < backend.hcl
gh secret set TERRAFORM_TFVARS  < terraform.tfvars
gh secret set SSH_PUBLIC_KEY      < ~/.ssh/hetzner_kube.pub
gh secret set SSH_PUBLIC_KEY_PROD < ~/.ssh/hetzner_kube_prod.pub

export TF_DATA_DIR=.terraform-linux
terraform workspace select dev
terraform output -raw ci_access_client_id     | gh secret set CF_ACCESS_CLIENT_ID
terraform output -raw ci_access_client_secret | gh secret set CF_ACCESS_CLIENT_SECRET
terraform workspace select production
terraform output -raw ci_access_client_id     | gh secret set CF_ACCESS_CLIENT_ID_PROD
terraform output -raw ci_access_client_secret | gh secret set CF_ACCESS_CLIENT_SECRET_PROD

gh variable set TERRAFORM_PLAN_ENABLED --body true
```

Each cluster's kube-API Access application trusts only its own service token,
which is why there are two pairs. Without `TERRAFORM_PLAN_ENABLED` the plan job
is skipped rather than failed, so the repository works before any of this is
configured.

**Re-run `gh secret set TERRAFORM_TFVARS < terraform.tfvars` after every change
to `terraform.tfvars`.** CI plans what that secret says, not what is on your
disk; a stale copy means CI plans an environment that does not exist.

### GitHub — each application repository

| Scope | Name | Value |
|---|---|---|
| environment `development` | `KUBE_CONFIG` | `terraform output -raw kubeconfig \| base64 -w0` in the `dev` workspace |
| environment `production` | `KUBE_CONFIG` | the same in the `production` workspace |
| environment `development` / `production` | `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` | that cluster's Access service token pair |
| repository | `GHCR_PULL_TOKEN` | the fine-grained PAT with `read:packages` |
| repository variable | `KUBERNETES_DEPLOY_ENABLED` | `true` once clusters, secrets and DNS are ready; leave unset before that |

### In the cluster — minted by Terraform

Nothing here is typed into `kubectl` by hand, and nothing is baked into an image
or a manifest:

| Secret | Namespace | Source |
|---|---|---|
| `tunnel-token` | `cloudflared` | the tunnel token, read from the Cloudflare API at apply time |
| `applim-env` / `applim-test-env` | `applim` / `applim-test` | `var.applim_env` from `terraform.tfvars`, referenced by the manifest as `optional` |
| `applim-litestream` / `applim-test-litestream` | `applim` / `applim-test` | R2 bucket credentials minted in `backups.tf` |
| `registry-ghcr` | each app namespace | created by the deploy workflow from `GHCR_PULL_TOKEN` |

The app namespace is created by the application's own deploy workflow, so deploy
an application once before the first apply that expects its Secrets.

## Runbooks

### Add an application

1. Add the site to `local.sites` in [services.tf](services.tf):

   ```hcl
   my-app = {
     production_hostname = "my-app.com"
     production_aliases  = ["www.my-app.com"]
     test_hostname       = "test.my-app.com"
   }
   ```

   The key is also the namespace and the Service name; the tunnel route is
   derived as `<key>.<key>.svc.cluster.local:80` in production and
   `<key>-test.<key>-test…` on dev.
2. Make sure every hostname's zone is in `cloudflare_zone_ids`. The
   `hostnames_have_zones` check in `modules/edge` fails the plan if not.
3. Copy [kubernetes/application.yaml](kubernetes/application.yaml) into the
   application repository and adjust it if the app needs more containers.
4. Add a `deploy` job to the application's CI that calls the reusable workflow:

   ```yaml
     deploy:
       needs: [test, e2e, docker]
       permissions:
         contents: read
         packages: write
       if: github.event_name == 'push' && vars.KUBERNETES_DEPLOY_ENABLED == 'true'
       uses: WannaBeKratos/infra/.github/workflows/deploy-application.yml@main
       with:
         app_name: my-app
         port: 8080
         health_path: /healthz
       secrets:
         KUBE_CONFIG: ${{ secrets.KUBE_CONFIG }}
         GHCR_PULL_TOKEN: ${{ secrets.GHCR_PULL_TOKEN }}
         CF_ACCESS_CLIENT_ID: ${{ secrets.CF_ACCESS_CLIENT_ID }}
         CF_ACCESS_CLIENT_SECRET: ${{ secrets.CF_ACCESS_CLIENT_SECRET }}
   ```

5. Set that repository's environment secrets, deploy the `development` branch,
   confirm the `test.*` hostname behind Access, then apply the `dev` workspace so
   any Terraform-managed Secret lands in the now-existing namespace.
6. Apply both workspaces.

### Rotate the R2 state token

The token in `bootstrap/` expires (see `expires_on` in
[bootstrap/main.tf](bootstrap/main.tf)); the applim feed token in
[backups.tf](backups.tf) rotates the same way.

```bash
terraform -chdir=bootstrap apply -replace=cloudflare_account_token.state -var-file=../terraform.tfvars
```

This rewrites `backend.hcl` with the new access key and secret. Then re-init the
root and refresh CI:

```bash
TF_DATA_DIR=.terraform-linux terraform init -reconfigure -backend-config=backend.hcl
gh secret set BACKEND_HCL < backend.hcl
```

For the feed token, `terraform apply -replace=cloudflare_account_token.applim_feed`
in each workspace; the `-litestream` Secret is rewritten in the same apply and
the pods pick it up on their next restart.

### Raise the agent count

`var.agent_counts` maps environment to agent servers, and
`modules/cluster` validates 1–5. One is the floor on purpose: a single-node
cluster makes kube-hetzner open ports 80/443 to the world for klipper-lb, which
the tunnel never needs. Five is the default Hetzner *project* server limit, and
the autoscaler's nodes count against it — ask Hetzner to raise the limit before
going near it.

```hcl
# variables.tf
agent_counts = {
  dev        = 1
  production = 3
}
```

Then plan and apply the affected workspace. Adding an agent is additive;
lowering the count destroys servers, so drain them first.
