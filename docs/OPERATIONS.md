# Operating the platform

The hands-on manual: first-time setup, the secrets model and the runbooks.
The README stays the map; this is the glovebox booklet.

## Quickstart for a fresh operator

### 1. One-time prerequisites

1. Two Hetzner Cloud projects, one per environment (say `projects-dev` and
   `projects-production`), each with its own read/write API token.
   kube-hetzner stores the token inside the cluster (`kube-system/hcloud`), so
   whoever owns one cluster owns its whole project; separate projects keep a dev
   compromise away from production. `hcloud_tokens` refuses two identical tokens.
2. Two passphrase-less SSH keypairs, so the environments never share node
   access:

   ```bash
   ssh-keygen -t ed25519 -N "" -f ~/.ssh/hetzner_kube
   ssh-keygen -t ed25519 -N "" -f ~/.ssh/hetzner_kube_prod
   ```

3. A MicroOS snapshot in **each** Hetzner project (Packer ≥ 1.16, once per
   project, with that project's token):

   ```bash
   export HCLOUD_TOKEN="<that project's token>"
   curl -LO https://raw.githubusercontent.com/kube-hetzner/terraform-hcloud-kube-hetzner/master/packer-template/hcloud-microos-snapshots.pkr.hcl
   packer init hcloud-microos-snapshots.pkr.hcl
   packer build hcloud-microos-snapshots.pkr.hcl
   ```

4. A Cloudflare API token with `Account > Cloudflare Tunnel:Edit`,
   `Account > Access: Apps and Policies:Edit`, `Account > Access: Service Tokens:Edit`,
   `Account > Workers R2 Storage:Edit`, `Account > Account API Tokens:Edit`, and
   `Zone:Read` + `DNS:Edit` + `Zone WAF:Edit` + `Zone Settings:Edit` on every
   zone that holds a hostname (the last two for the rate limit, URL
   normalization and TLS settings in `modules/edge`).
5. A GitHub PAT with `read:packages` **and an expiry date**, for the in-cluster
   image pull secret. The workflow's own `GITHUB_TOKEN` expires and cannot serve
   as one. If the images hold nothing private, making the GHCR packages public
   removes the need for this token altogether.
6. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill it in: account
   ID, zone IDs, your own CIDR for the two firewall variables, and the e-mail
   addresses Access should let through. This file never enters git.

### 2. Bootstrap the state backend

Chicken-and-egg: the R2 bucket that holds the state has to exist before the
backend can be configured, so `bootstrap/` keeps its own local state. Run it
once. It creates the bucket, mints a read/write token for you and a read-only
one for CI, and writes `backend.hcl` and `backend-ci.hcl`.

```bash
export TF_VAR_cloudflare_api_token="..."
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply -var-file=../terraform.tfvars
```

State locking uses R2's conditional writes (`use_lockfile`). CI plans with
`-lock=false`, which is why its token can be read-only.
`backend.hcl.example` documents the manual fallback if you ever mint the token
by hand.

### 3. Plan and apply, from WSL

Applies are manual by policy. They run from WSL so the providers are
`linux_amd64`; `TF_DATA_DIR=.terraform-linux` keeps that plugin cache separate
from the `windows_amd64` one in `.terraform/`, so the same checkout serves both
shells without re-initialising on every switch.

```bash
export TF_DATA_DIR=.terraform-linux
export TF_VAR_hcloud_tokens='{"dev":"...","production":"..."}'
export TF_VAR_cloudflare_api_token="..."

terraform init -backend-config=backend.hcl
terraform workspace new dev          # `select` on later runs
terraform plan -out=tfplan
terraform apply tfplan
```

Repeat for `production` (`terraform workspace new production`). The `default`
workspace is rejected on purpose. Then write the admin kubeconfig, which stays
on your machine, and check the cluster:

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
| `backend.hcl` | the read/write R2 access key and secret for the state bucket (yours) |
| `backend-ci.hcl` | the read-only pair, for CI's `BACKEND_HCL` |
| `bootstrap/terraform.tfstate` | both R2 state tokens in clear — the one state file that is not remote |
| `*_kubeconfig.yaml`, `~/.kube/*` | cluster admin credentials: `system:masters`, not revocable, never handed to a repository |
| `~/.ssh/hetzner_kube{,_prod}` | node SSH keys |
| `tfplan`, `apply-*.log`, `.terraform/`, `.terraform-linux/` | plan and provider artefacts, which contain resolved values |

Terraform state contains cluster credentials, and reading it is enough to own
both clusters. Treat the R2 bucket as a secret store, not as a build artefact.

### GitHub — this repository

The plan job runs the branch's own code with these secrets, so they live in the
`terraform-plan` **environment**, not at repository level. Give that
environment a required reviewer (yourself) and every plan waits for a click
before it can touch them; without one it behaves as before. Set them from WSL
with the workspace selected, because the Access tokens are per-cluster outputs:

```bash
E=terraform-plan
gh secret set --env $E BACKEND_HCL         < backend-ci.hcl
gh secret set --env $E TERRAFORM_TFVARS    < terraform.tfvars
gh secret set --env $E SSH_PUBLIC_KEY      < ~/.ssh/hetzner_kube.pub
gh secret set --env $E SSH_PUBLIC_KEY_PROD < ~/.ssh/hetzner_kube_prod.pub

export TF_DATA_DIR=.terraform-linux
terraform workspace select dev
terraform output -json ci_access_tokens | jq -r .infra.client_id     | gh secret set --env $E CF_ACCESS_CLIENT_ID
terraform output -json ci_access_tokens | jq -r .infra.client_secret | gh secret set --env $E CF_ACCESS_CLIENT_SECRET
terraform workspace select production
terraform output -json ci_access_tokens | jq -r .infra.client_id     | gh secret set --env $E CF_ACCESS_CLIENT_ID_PROD
terraform output -json ci_access_tokens | jq -r .infra.client_secret | gh secret set --env $E CF_ACCESS_CLIENT_SECRET_PROD

gh variable set TERRAFORM_PLAN_ENABLED --body true
```

`TERRAFORM_TFVARS` must carry `hcloud_tokens` and `cloudflare_api_token` too:
CI has no other source for them.

Each cluster's kube-API Access application trusts only its own service tokens,
which is why there are two pairs. Without `TERRAFORM_PLAN_ENABLED` the plan job
is skipped rather than failed, so the repository works before any of this is
configured.

**Re-run `gh secret set --env terraform-plan TERRAFORM_TFVARS < terraform.tfvars`
after every change to `terraform.tfvars`.** CI plans what that secret says, not
what is on your disk; a stale copy means CI plans an environment that does not
exist.

### GitHub — each application repository

Everything that reaches a cluster is **environment**-scoped, never repository
secrets: a repository secret is readable by any workflow on any branch.

| Scope | Name | Value |
|---|---|---|
| environment `development` | `KUBE_CONFIG` | `terraform output -json deployer_kubeconfigs \| jq -r .<app> \| base64 -w0` in the `dev` workspace |
| environment `production` | `KUBE_CONFIG` | the same in the `production` workspace |
| environment `development` / `production` | `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` | `ci_access_tokens.<app>` from that workspace |
| repository | `GHCR_PULL_TOKEN` | the `read:packages` PAT, with an expiry |
| repository variable | `KUBERNETES_DEPLOY_ENABLED` | `true` once clusters, secrets and DNS are ready; leave unset before that |
| repository variable | `KUBE_API_HOST_DEV` / `KUBE_API_HOST_PROD` | the kube-API hostnames (`terraform output kube_api_hostname`) |

And two settings, because the deploy workflow cannot stop a caller that lies
about its production branch:

- **Protect `main`** (branch protection or a ruleset). A production deploy from
  an unprotected branch fails on purpose.
- **Environment `production` → Deployment branches: `main` only**, and
  `development` → `development` only. This is the gate that holds even against a
  workflow file written to read the secrets directly.

### In the cluster — minted by Terraform

Nothing here is typed into `kubectl` by hand, and nothing is baked into an image
or a manifest:

| Secret | Namespace | Source |
|---|---|---|
| `tunnel-token` | `cloudflared` | the tunnel token, read from the Cloudflare API at apply time |
| `deployer-token` | each app namespace | the `deployer` ServiceAccount's token, behind `deployer_kubeconfigs` |
| `applim-env` / `applim-test-env` | `applim` / `applim-test` | `var.applim_env` from `terraform.tfvars`, referenced by the manifest as `optional` |
| `applim-litestream` / `applim-test-litestream` | `applim` / `applim-test` | R2 bucket credentials minted in `backups.tf` |
| `registry-ghcr` | each app namespace | created by the deploy workflow from `GHCR_PULL_TOKEN` |
| `hcloud`, `hcloud-csi` | `kube-system` | that environment's Hetzner token, placed by kube-hetzner |

App namespaces are Terraform's (`services.tf`), so apply before an app's first
deploy, not after.

## Runbooks

### Migrate to the hardened setup (one time)

For clusters built before the per-app deployer, the per-environment Hetzner
projects and the edge rules. Dev moves to a new Hetzner project; production
stays where it is.

1. **Cloudflare token.** Add `Zone WAF:Edit` and `Zone Settings:Edit` (and the
   Access permissions, if it lacked them) as in prerequisite 4.
2. **Modules and variables.** In `terraform.tfvars` (or your environment),
   replace `hcloud_token` with the `hcloud_tokens` map. Then
   `terraform init -backend-config=backend.hcl`, which fetches kube-hetzner from
   its pinned commit instead of the registry.
3. **CI state token.** `terraform -chdir=bootstrap apply -var-file=../terraform.tfvars`
   mints the read-only token and writes `backend-ci.hcl`.
4. **Move dev to its own project.** Create the new Hetzner project, its token and
   its snapshot (prerequisites 1 and 3). The in-cluster resources die with the old
   cluster, so drop them from state instead of destroying them one by one. Destroy
   only the cluster, with a *second* token from the current project (the variable
   rejects two identical tokens), and rebuild it in the new project. The tunnel,
   DNS, Access and the R2 feed bucket are untouched:

   ```bash
   terraform workspace select dev
   export TF_VAR_hcloud_tokens='{"dev":"<second token, current project>","production":"<production token>"}'
   terraform state list | grep -E '(^|\.)(kubernetes_|helm_)' | xargs terraform state rm
   terraform destroy -target=module.cluster
   export TF_VAR_hcloud_tokens='{"dev":"<new dev project token>","production":"<production token>"}'
   terraform plan -out=tfplan && terraform apply tfplan
   ```

   Then delete the second token from the current project.
5. **Production.** First do steps 7–8 for the `development` environment only,
   redeploy the app to dev, and check its pods stay Ready behind the new
   NetworkPolicy and Pod Security labels. Then
   adopt the app namespaces the deploy workflow created in production, and
   apply. In the plan, no `hcloud_server` may be replaced. kube-hetzner re-runs
   its add-on kustomization for the new CCM setting, and that is expected:

   ```bash
   terraform workspace select production
   terraform import 'kubernetes_namespace_v1.app["applim"]' applim   # one per existing app
   terraform plan -out=tfplan && terraform apply tfplan
   ```

   A zone that already has a dashboard-made rate limiting rule fails on
   `cloudflare_ruleset.rate_limit`: import it with
   `terraform import 'module.edge.cloudflare_ruleset.rate_limit["<zone>"]' 'zones/<zone_id>/<ruleset_id>'`
   and apply again.
6. **Retire the shared Access token.** The old single token is now `infra`'s,
   but every app repository has held a copy. Replace it in both workspaces:
   `terraform apply -replace='module.edge.cloudflare_zero_trust_access_service_token.ci["infra"]'`.
7. **GitHub.** Set this repository's secrets in `terraform-plan` as above and
   delete the old repository-level copies (`gh secret delete BACKEND_HCL`, and so
   on). In each app repository, set the environment secrets and the two settings
   from the secrets model, and delete the repository-level `KUBE_CONFIG` and
   `CF_ACCESS_*` copies.
8. **App manifests.** In each app repository's copy of
   `kubernetes/application.yaml`, delete the `Namespace` document (the deployer
   cannot touch namespaces) and adopt the new `securityContext`, `/tmp`
   `emptyDir` and `automountServiceAccountToken: false`. The image needs a
   numeric non-root `USER`. Pin the reusable workflow to a commit
   (`deploy-application.yml@<sha>`) rather than `@main`.
9. **Pod Security.** Once an app deploys without `restricted` warnings, set
   `pod-security.kubernetes.io/enforce` to `restricted` in `services.tf`.
10. **Old admin certificates.** Dev's died with its cluster. Production's admin
    kubeconfig sat in app repositories and cannot be revoked. If any of those
    repositories may have been exposed, rotate the k3s CA on the production
    cluster (k3s docs, "Certificate Management").

### Add an application

1. Add the site to `sites` in `terraform.tfvars`:

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
3. Apply both workspaces. This creates the app's namespace, its `deployer` and
   its own Access service token.
4. Copy [kubernetes/application.yaml](../kubernetes/application.yaml) into the
   application repository and adjust it if the app needs more containers. Any
   extra kinds it applies need adding to the `deployer` Role in `services.tf`.
5. Add a `deploy` job to the application's CI that calls the reusable workflow,
   pinned to a commit of this repository:

   ```yaml
     deploy:
       needs: [test, e2e, docker]
       permissions:
         contents: read
         packages: write
       if: github.event_name == 'push' && vars.KUBERNETES_DEPLOY_ENABLED == 'true'
       uses: WannaBeKratos/infra/.github/workflows/deploy-application.yml@<commit-sha>
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

6. Give the repository the full caller kit from "GitHub — each application
   repository" above: environment secrets, variables, the protected `main` and
   the environment branch policies. Reusable workflows read secrets and
   variables from the CALLING repository; miss one and the deploy fails in the
   tunnel step.
7. Deploy the `development` branch and confirm the `test.*` hostname behind
   Access, then promote to `main`.

### Rotate a deploy credential

Both are per app, so one leak is one rotation. Run each in the affected
workspace, then set the new value in that app repository's environment:

```bash
terraform apply -replace='kubernetes_secret_v1.deployer_token["my-app"]'                            # KUBE_CONFIG
terraform apply -replace='module.edge.cloudflare_zero_trust_access_service_token.ci["my-app"]'     # CF_ACCESS_*
```

Deleting the old `deployer-token` Secret kills its token at once. Access service
tokens also expire after a year (`duration`), so put a reminder in the calendar.

The tunnel token has no expiry, and whoever holds it can take a share of the
tunnel's traffic. Rotate it by replacing the tunnel:
`terraform apply -replace=module.edge.cloudflare_zero_trust_tunnel_cloudflared.cluster`.
DNS and the pod follow in the same apply, with a short blip while the CNAMEs
switch.

### Rotate the R2 state token

The tokens in `bootstrap/` expire (see `expires_on` in
[bootstrap/main.tf](../bootstrap/main.tf)); the applim feed token in
[backups.tf](../backups.tf) rotates the same way.

```bash
terraform -chdir=bootstrap apply -replace=cloudflare_account_token.state -replace=cloudflare_account_token.state_ci -var-file=../terraform.tfvars
```

This rewrites `backend.hcl` and `backend-ci.hcl`. Then re-init the root and
refresh CI:

```bash
TF_DATA_DIR=.terraform-linux terraform init -reconfigure -backend-config=backend.hcl
gh secret set --env terraform-plan BACKEND_HCL < backend-ci.hcl
```

For the feed token, `terraform apply -replace=cloudflare_account_token.applim_feed`
in each workspace; the `-litestream` Secret is rewritten in the same apply and
the pods pick it up on their next restart.

### Bump cloudflared or kubectl-argo-rollouts

Dependabot only bumps actions. For cloudflared, take the new version's
`cloudflared-linux-amd64` SHA-256 from its GitHub release notes and the image
index digest from Docker Hub. Update `modules/edge/main.tf` and both workflows
together. For kubectl-argo-rollouts, match the controller the chart in
`rollouts.tf` installs (its `appVersion`) and take the hash from that release's
`argo-rollouts-checksums.txt`.

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
