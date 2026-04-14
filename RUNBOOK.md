# Platform Runbook

Operational guide for platform engineers and application developers. Read DECISIONS.md first to understand *why* things are structured this way before changing them.

---

## Repository Map

| Repo | Owner | Purpose |
|------|-------|---------|
| `repo-app` | App team | Source code, Dockerfile, CI pipeline |
| `repo-app-gitops` | App team | Helm values per env — the only thing app team touches for deployments |
| `repo-helm-chart` | Shared | Generic Helm chart used by all apps |
| `repo-platform-gitops` | Platform team | All ArgoCD config: AppSets, cluster registry, platform tool configs |
| `repo-platform-infra` | Platform team | Terraform (cluster provisioning) + one-time bootstrap seed |

**Rule:** App team never touches platform repos. Platform team never edits app values (they own the *mechanism*, not the *configuration*).

---

## Architecture at a Glance

```
Terraform (repo-platform-infra)
  └── provisions KIND cluster + installs ArgoCD
        └── kubectl apply root-app.yaml
              └── platform-root Application (watches repo-platform-gitops/argocd-apps/)
                    ├── appset-platform.yaml  [sync-wave: -1]
                    │     matrix: clusters/*.yaml × platform-apps/*/config.yaml
                    │     └── dev-kube-prometheus-stack, stg-kube-prometheus-stack, ...
                    │     └── dev-metrics-server, stg-metrics-server, ...
                    │
                    └── appset-apps.yaml  [sync-wave: 0]
                          matrix: clusters/*.yaml × apps/* (repo-app-gitops)
                          └── dev-devops-test-webserver, stg-devops-test-webserver, ...
```

**Sync order guarantee:** Platform tools (Prometheus, metrics-server) are always fully healthy before any application pod is scheduled. This is enforced by ArgoCD sync-waves, not by timing.

---

## Platform Engineer Workflows

### Bootstrap a New Cluster from Scratch

This is the full recovery procedure. Run this when standing up a new cluster or rebuilding after a disaster.

**Prerequisites:**
- Docker installed and running
- `terraform`, `kubectl`, `kind` CLIs installed
- GitHub PAT with repo read access stored as `TF_VAR_github_auth_token`

```bash
cd repo-platform-infra/terraform-kind

# 1. Provision the cluster and install ArgoCD
terraform init
terraform apply

# 2. Export the kubeconfig
kind export kubeconfig --name devops-test

# 3. Wait for ArgoCD to be ready
kubectl wait --for=condition=available deployment/argo-cd-argocd-server \
  -n argocd --timeout=120s

# 4. Apply the bootstrap seed — this is the only manual step
kubectl apply -f ../bootstrap/root-app.yaml

# 5. Watch ArgoCD take over
kubectl get applications -n argocd -w
```

After step 4, ArgoCD reads `repo-platform-gitops/argocd-apps/`, creates both AppSets, and begins syncing. Platform tools deploy first (wave -1), then app workloads (wave 0). The full stack is typically healthy in 5–10 minutes.

**Nothing else is required.** No manual Helm installs, no kubectl apply for applications, no coordination with the app team.

---

### Add a New Environment / Cluster

Adding a new environment means telling the cluster registry about it. Both AppSets discover it automatically.

**Step 1:** Add the cluster file to `repo-platform-gitops`:

```yaml
# clusters/dr.yaml
env: dr
cluster: https://kubernetes.dr.svc
helmChartRevision: "0.1.0"   # pin for production-like envs
prune: false                  # safe default for new envs
```

**Step 2:** Add values files for platform tools:

```bash
mkdir -p platform-apps/kube-prometheus-stack/dr
mkdir -p platform-apps/metrics-server/dr

# Copy from prod as a starting point, adjust as needed
cp platform-apps/kube-prometheus-stack/prod/values.yaml \
   platform-apps/kube-prometheus-stack/dr/values.yaml
cp platform-apps/metrics-server/prod/values.yaml \
   platform-apps/metrics-server/dr/values.yaml
```

**Step 3:** Coordinate with app teams to add their env values:

```bash
# In repo-app-gitops (app team does this):
mkdir -p apps/devops-test-webserver/dr
cp apps/devops-test-webserver/prod/values.yaml \
   apps/devops-test-webserver/dr/values.yaml
# Edit the copy with DR-specific image tag, replica count, etc.
```

**Step 4:** Commit and push `repo-platform-gitops`. ArgoCD detects the new `clusters/dr.yaml` and creates `dr-kube-prometheus-stack`, `dr-metrics-server`, `dr-devops-test-webserver` Applications automatically.

**What does NOT need to change:** `appset-apps.yaml`, `appset-platform.yaml`, Terraform, `root-app.yaml`. The AppSets are frozen policy.

---

### Add a New Platform Tool

Platform tools are external Helm charts deployed to all clusters.

**Step 1:** Create the tool directory:

```bash
mkdir -p platform-apps/cert-manager/{dev,stg,prod}
```

**Step 2:** Write `config.yaml` with chart identity:

```yaml
# platform-apps/cert-manager/config.yaml
chart: cert-manager
repoURL: https://charts.jetstack.io
targetRevision: "v1.14.*"
namespace: cert-manager
```

**Step 3:** Write per-env values:

```yaml
# platform-apps/cert-manager/dev/values.yaml
installCRDs: true
replicaCount: 1

# platform-apps/cert-manager/prod/values.yaml
installCRDs: true
replicaCount: 3
resources:
  requests:
    cpu: 100m
    memory: 128Mi
```

**Step 4:** Commit and push. ArgoCD deploys `dev-cert-manager`, `stg-cert-manager`, `prod-cert-manager` to their respective clusters within minutes.

**Important:** `config.yaml` fields (`chart`, `repoURL`, `targetRevision`, `namespace`) are the only ones the AppSet template reads. Do not add fields not referenced by the template — they are silently ignored.

---

### Upgrade a Platform Tool

**For patch upgrades** (covered by the `*` wildcard in `targetRevision`): No action needed. ArgoCD detects the new chart version on its next reconciliation and upgrades automatically.

**For minor/major upgrades:**

```yaml
# platform-apps/kube-prometheus-stack/config.yaml
targetRevision: "55.*"   # was "51.*"
```

Commit and push. ArgoCD upgrades all envs simultaneously. If you want to test on dev first:

1. Change `targetRevision` in config.yaml
2. Temporarily add an override in `dev/values.yaml` to validate
3. Once validated, commit

**For rollback:** Revert the `targetRevision` change in Git. ArgoCD downgrades within minutes.

---

### Modify Cluster Behaviour (prune, helm chart version)

Cluster-level controls live in `clusters/<env>.yaml`. These affect every app deployed to that cluster.

```yaml
# clusters/prod.yaml
helmChartRevision: "0.1.1"   # bump after validating on dev/stg
prune: false                  # keep false in prod unless deliberately enabling
```

**When to change `helmChartRevision` in prod:**
1. Validate the new chart version is stable on dev (runs HEAD automatically)
2. Validate on stg
3. Update `clusters/prod.yaml` with the pinned version tag
4. Commit — ArgoCD rolls out the chart upgrade to all prod apps

**When to temporarily enable `prune: true` in prod:** If you need to remove a decommissioned app from prod, enable prune, wait for ArgoCD to clean up, then disable it again. Never leave prod prune enabled long-term.

---

### Respond to a Sync Failure

ArgoCD retries 3 times with exponential backoff (10s, 20s, 40s, max 2m). If all retries fail:

```bash
# Check which application is failing
kubectl get applications -n argocd

# Get detailed status
kubectl describe application dev-devops-test-webserver -n argocd

# Check ArgoCD events
kubectl get events -n argocd --sort-by='.lastTimestamp'

# Force a manual sync (after fixing the root cause)
argocd app sync dev-devops-test-webserver
```

**Common causes:**
- Bad values.yaml (YAML syntax error) → fix the file, push, ArgoCD re-syncs
- Chart version not found (bad targetRevision) → fix `config.yaml` or `clusters/<env>.yaml`
- Cluster unreachable → infrastructure issue, check cluster health first
- CRD conflict → use `ServerSideApply=true` in syncOptions (already enabled for platform apps)

---

### Rollback an Application

**Option A — Revert the Git commit (preferred):**

```bash
# In repo-app-gitops
git revert HEAD
git push
# ArgoCD auto-syncs the previous values, Kubernetes rolls back the deployment
```

**Option B — Manual ArgoCD rollback (emergency only):**

```bash
argocd app rollback prod-devops-test-webserver
# WARNING: this creates drift between Git and cluster state
# Follow up immediately with a git revert to restore Git as source of truth
```

---

## Application Developer Workflows

### Onboard a New Application

The platform team does not need to be involved. The AppSet auto-discovers any directory added under `apps/` in `repo-app-gitops`.

**Step 1:** Create env directories and values files:

```bash
# In repo-app-gitops
mkdir -p apps/payments-service/{dev,stg,prod}
```

**Step 2:** Write values for each env:

```yaml
# apps/payments-service/dev/values.yaml
replicaCount: 1
image:
  repository: ghcr.io/acme/payments-service
  tag: "latest"
envVariables:
  ENV: development
  DB_URL: postgres://dev-db:5432/payments
ingress:
  enabled: true
  hosts:
    - host: dev.payments.internal
      paths:
        - path: /
          pathType: Prefix
```

```yaml
# apps/payments-service/prod/values.yaml
replicaCount: 3
image:
  repository: ghcr.io/acme/payments-service
  tag: "1.0.0"
canary:
  enabled: true
resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 200m
    memory: 256Mi
envVariables:
  ENV: production
  DB_URL: postgres://prod-db:5432/payments
ingress:
  enabled: true
  hosts:
    - host: payments.acme.com
      paths:
        - path: /
          pathType: Prefix
```

**Step 3:** Commit and push to `repo-app-gitops`. ArgoCD creates `dev-payments-service`, `stg-payments-service`, `prod-payments-service` within 3 minutes (the AppSet's default reconciliation interval).

**No platform team involvement required.**

---

### Daily Development Workflow

```
Write code → push to feature branch → open PR → CI runs (lint + build + scan)
                                                        │
                                             PR merged to main
                                                        │
                                             CI builds image (sha-abc1234)
                                             CI updates dev/values.yaml image.tag
                                                        │
                                             ArgoCD detects change in repo-app-gitops
                                             ArgoCD syncs dev-<appname>
                                                        │
                                             Validate on dev
```

**Check dev deployment status:**

```bash
kubectl get pods -n devops-test-webserver
kubectl describe application dev-devops-test-webserver -n argocd
```

---

### Promote a Release to Staging

Staging promotion is a manual Git operation — the app team owns it.

```bash
# In repo-app-gitops
# Copy the image tag from dev/values.yaml to stg/values.yaml
vim apps/devops-test-webserver/stg/values.yaml
# Update: image.tag: "sha-abc1234"
git add apps/devops-test-webserver/stg/values.yaml
git commit -m "chore: promote sha-abc1234 to stg"
git push
```

ArgoCD detects the change and syncs stg automatically.

---

### Release to Production

Production promotion is triggered by creating a Git tag. CI handles the values file update.

```bash
# In repo-app (source code repo)
git tag v1.2.0
git push origin v1.2.0
```

**What happens automatically:**
1. CI builds the image and tags it `1.2.0` (semver from the git tag)
2. CI updates `apps/devops-test-webserver/prod/values.yaml` with `image.tag: "1.2.0"`
3. ArgoCD detects the change and syncs `prod-devops-test-webserver`
4. Since prod uses Argo Rollouts canary (`canary.enabled: true`), the rollout is gradual:
   - 20% traffic to new version → pause 10s
   - 50% traffic to new version → pause 10s
   - 100% traffic to new version

**Monitor the canary:**

```bash
kubectl argo rollouts get rollout devops-test-webserver -n devops-test-webserver --watch
```

**Abort a canary in progress:**

```bash
kubectl argo rollouts abort devops-test-webserver -n devops-test-webserver
# Then revert the prod/values.yaml commit in repo-app-gitops
```

---

### Roll Back a Production Deployment

```bash
# Option A: revert the image tag in Git (preferred — keeps Git as truth)
cd repo-app-gitops
git revert HEAD   # reverts the prod/values.yaml change
git push
# ArgoCD syncs, Argo Rollouts rolls back to previous stable version

# Option B: emergency ArgoCD rollback (creates git drift — use only if option A is too slow)
kubectl argo rollouts undo devops-test-webserver -n devops-test-webserver
# Follow up with git revert immediately
```

---

### Enable/Disable Canary for an Application

Canary is a per-app, per-env configuration. Set it in the env's `values.yaml`:

```yaml
# apps/myapp/prod/values.yaml
canary:
  enabled: true           # uses Argo Rollouts instead of standard Deployment
  steps:
    - setWeight: 10       # optional: override default steps
    - pause: {duration: 30s}
    - setWeight: 50
    - pause: {duration: 30s}
```

Setting `canary.enabled: false` (or omitting it) deploys a standard Kubernetes Deployment. The Helm chart handles the conditional rendering — no other changes needed.

---

### Configure Environment Variables

Environment variables are injected via a ConfigMap. Set them in `values.yaml`:

```yaml
envVariables:
  DATABASE_URL: "postgres://host:5432/mydb"
  REDIS_URL: "redis://redis:6379"
  FEATURE_FLAG_NEW_UI: "true"
```

For secrets, **do not put secret values in values.yaml** (it's a Git repo). Instead, create a Kubernetes Secret manually or via ESO, and reference it in the pod spec using a chart override. Talk to the platform team about the preferred secrets management approach for your cluster.

---

## Reference: What Lives Where

| Concern | Location | Who changes it |
|---------|----------|----------------|
| Image tag (dev) | `repo-app-gitops/apps/<app>/dev/values.yaml` | CI (automated) |
| Image tag (stg) | `repo-app-gitops/apps/<app>/stg/values.yaml` | App team (manual PR) |
| Image tag (prod) | `repo-app-gitops/apps/<app>/prod/values.yaml` | CI on git tag (automated) |
| Replica count | `repo-app-gitops/apps/<app>/<env>/values.yaml` | App team |
| Canary config | `repo-app-gitops/apps/<app>/prod/values.yaml` | App team |
| Resource limits | `repo-app-gitops/apps/<app>/<env>/values.yaml` | App team |
| Cluster list | `repo-platform-gitops/clusters/*.yaml` | Platform team |
| Prune policy | `repo-platform-gitops/clusters/<env>.yaml` | Platform team |
| Helm chart version (per cluster) | `repo-platform-gitops/clusters/<env>.yaml` | Platform team |
| Platform tool versions | `repo-platform-gitops/platform-apps/<tool>/config.yaml` | Platform team |
| Platform tool values | `repo-platform-gitops/platform-apps/<tool>/<env>/values.yaml` | Platform team |
| ArgoCD ApplicationSets | `repo-platform-gitops/argocd-apps/` | Platform team |
| Cluster provisioning | `repo-platform-infra/terraform-kind/` | Platform team |
| Bootstrap seed | `repo-platform-infra/bootstrap/root-app.yaml` | Platform team |
| Application source code | `repo-app/` | App team |
| Helm chart templates | `repo-helm-chart/templates/` | Shared / platform team |
