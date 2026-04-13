# Architecture Decision Log

This document captures every design decision made during the evolution of this platform, including the dead ends, pivots, and the reasoning behind each choice. Read this before making changes — the "why" matters as much as the "what".

---

# Phase 1: Gemini — Foundation & Bootstrap (Pre-Claude)

The following decisions were made during the initial Gemini-driven session that established the foundational architecture from scratch.

---

## Decision G1: Four-Repo Architecture

**Problem:** How to structure the codebase for a 12-factor CI/CD platform targeting OpenShift.

**Decision:** Four independent repositories with strict separation of concerns:
- `repo-app` — Application source code, Dockerfile, CI pipeline definition
- `repo-helm-chart` — Generic, reusable Helm chart (shared across all apps)
- `repo-platform` (later split into `repo-platform-infra` + `repo-platform-gitops`) — ArgoCD config, bootstrap, Terraform
- `repo-app-gitops` — Per-app, per-environment `values.yaml` files only

**Why:** Strict 12-factor compliance. Each repo has a single owner, a single change rate, and a single blast radius. App developers never touch infrastructure. Platform engineers never touch application source code.

---

## Decision G2: Generic Helm Chart with Argo Rollouts Toggle

**Problem:** Should every app have its own Helm chart, or share a common one?

**Decision:** A single generic Helm chart in `repo-helm-chart` that renders either a standard `Deployment` or an Argo `Rollout` based on a `canary.enabled` toggle in values.

**Why:** Most stateless microservices need identical infrastructure (Deployment, Service, Ingress, ConfigMap). Duplicating charts per app creates massive drift risk. The generic chart is versioned independently — the platform team controls the infrastructure contract, app teams only supply values.

**Trade-off acknowledged:** If an app needs truly unique infrastructure (e.g., StatefulSet, CronJob), it would need its own chart. That's the exception, not the rule.

---

## Decision G3: Multi-Source ArgoCD ApplicationSet

**Problem:** How does ArgoCD combine the generic Helm chart (logic) with per-app values (data)?

**Decision:** ArgoCD Multi-Source pattern inside an ApplicationSet:
- **Source 1:** `repo-helm-chart` — the templates
- **Source 2:** `repo-app-gitops` — the `values.yaml` files, referenced via `$values`

The ApplicationSet uses a `git directories` generator scanning `apps/*/*` to auto-discover apps and environments.

**Why:** App teams never need to understand Helm chart dependencies or `Chart.yaml`. They just write simple YAML values. The platform team retains centralized control to patch the underlying chart across the fleet.

---

## Decision G4: GitHub Actions CI with Trivy — Non-Blocking Security Scanning

**Problem:** How to handle container image vulnerability scanning in CI without blocking every build on unfixed upstream CVEs.

**Decision:** Trivy scans run with `continue-on-error: true` and output in `table` format to stdout. The step is visually marked in GitHub Actions UI but does not fail the pipeline.

**Why:** Base images like `nginx:alpine` routinely carry unfixed upstream CVEs that the app team cannot remediate. Blocking the pipeline on these creates alert fatigue and leads teams to skip scanning entirely. The table output ensures vulnerabilities are visible and auditable in the build log without creating false gates.

---

## Decision G5: GHCR over Docker Hub — Keyless Authentication

**Problem:** Where to push container images from CI, and how to authenticate.

**Decision:** Push to `ghcr.io` using GitHub's native `GITHUB_TOKEN` via OIDC. No static credentials required.

**Why:** Docker Hub does not support OIDC-based keyless auth from GitHub Actions. Using `ghcr.io` eliminates the need for long-lived PAT secrets stored in repo settings. The `GITHUB_TOKEN` is ephemeral, scoped, and automatically rotated per workflow run.

---

## Decision G6: Client-Side Date Rendering over Nginx SSI

**Problem:** The app needed to display the current date/time. The initial approach used Nginx Server-Side Includes (SSI).

**Decision:** Replaced SSI with a simple `<script>` block using `Date.toLocaleString()` in the browser.

**Why:** SSI adds server-side processing complexity to what should be a static file server. Client-side rendering respects the user's timezone and locale automatically, which SSI cannot do. Simpler Nginx config, fewer moving parts.

---

## Decision G7: ServerSideApply for kube-prometheus-stack

**Problem:** ArgoCD sync failed with `metadata.annotations: Too long: must have at most 262144 bytes` on Prometheus CRDs.

**Decision:** Added `ServerSideApply=true` to the `syncOptions` of the `kube-prometheus-stack` Application.

**Why:** The Prometheus CRDs are enormous. Standard `kubectl apply` stores the entire last-applied config as an annotation, which exceeds the 256KB Kubernetes annotation limit. Server-Side Apply shifts state tracking to the API server itself, bypassing the annotation entirely. This is a well-known issue with the kube-prometheus-stack chart.

---

## Decision G8: Terraform Bootstrap with Kind + ArgoCD + Repo-Creds

**Problem:** How to provision the local development cluster and seed it with ArgoCD.

**Decision:** A Terraform module in `terraform-kind/` that:
1. Provisions a multi-node Kind cluster via `tehcyx/kind` provider
2. Installs ArgoCD via `hashicorp/helm` provider (dynamically configured from cluster output)
3. Creates a `repo-creds` Kubernetes secret granting ArgoCD org-wide GitHub access
4. Runs `kubectl apply -f ../bootstrap/` via `null_resource` local-exec to apply the root App-of-Apps

**Why:** Single `terraform apply` takes you from zero to a fully operational GitOps cluster. No manual steps. The `repo-creds` pattern (vs individual repo secrets) means any new repo under the org is automatically accessible to ArgoCD.

**Security:** `terraform.tfvars` containing the GitHub PAT is `.gitignore`d. The `github_auth_token` variable is marked `sensitive`.

---

## Decision G9: Decoupling App Workloads from Platform — The Pivot Point

**Problem:** The original design had application ApplicationSets and environment configs (`apps/`) co-located inside `repo-platform`. This violated the strict boundary between app and platform concerns.

**Attempt 1 — Separate Root Application:** Created `root-apps.yaml` in `repo-platform/bootstrap/` pointing at `repo-app-gitops/argocd-apps/`. This moved the AppSet YAML to the app-gitops repo but left a stale multi-source `$values` reference pointing back at `repo-platform`.

**Attempt 2 — Matrix Cluster Generator:** Replaced the flat git directory generator with a `matrix` generator cross-referencing directory names against ArgoCD cluster secrets labeled with `environment: dev`. Required creating `cluster-dev.yaml` as a Kubernetes secret with labels.

**Why it was abandoned by the user:** Too implicit. The environment-to-cluster mapping was hidden inside Kubernetes labels rather than being explicit in Git. The user's feedback: "I don't like this approach."

**Attempt 3 — Per-Environment AppSet Files:** Created `appset-dev.yaml`, `appset-stg.yaml`, `appset-prod.yaml` — each hardcoding a specific directory glob (`apps/*/dev`) and cluster URL.

**Why it was abandoned by the user:** Not DRY. Three nearly identical files with only two values different. The user's feedback: "I don't like this either, it's not DRY anymore."

**This is where Claude took over.** The core tension — DRY vs. explicit, single-AppSet vs. per-env — is the exact problem Claude's Decision 1 onwards addresses.

---

# Phase 2: Claude — Iteration & Final Architecture

---

## Starting Point

The original architecture had three separate ApplicationSet files in `repo-app-gitops`:

```
repo-app-gitops/argocd-apps/
  appset-dev.yaml    # git directory generator on apps/*/dev
  appset-stg.yaml    # git directory generator on apps/*/stg
  appset-prod.yaml   # git directory generator on apps/*/prod
```

Each hardcoded its env name and cluster URL. Adding a new environment meant copy-pasting a file and changing two values. Adding a new cluster to an existing env meant touching each file. The complaint: **per-env AppSet pattern doesn't scale**.

---

## Decision 1: Git Files Generator with config.yaml

**Attempt:** Replace 3 AppSets with 1 using a git files generator on `apps/*/*/config.yaml`. Each env directory would have a minimal `config.yaml` containing just the cluster URL. Path segments (`path[1]` = app, `path[2]` = env) would drive the rest.

**Why it seemed good:** Single AppSet, auto-discovers all apps and envs, no per-env boilerplate.

**Why it was abandoned:** The `config.yaml` files were a different kind of boilerplate — one per env per app. The user's core objection was that anything per-env is duplication. Replacing three AppSet files with N config.yaml files is a lateral move, not an improvement.

**Lesson:** Reducing file count at the AppSet level doesn't help if you push the duplication into the data layer.

---

## Decision 2: Kustomize App-of-Apps

**Attempt:** Replace ApplicationSets entirely with Kustomize overlays managing ArgoCD Application resources directly.

```
argocd-apps/
  base/
    devops-test-webserver.yaml   # base Application resource
    kustomization.yaml
  overlays/
    dev/kustomization.yaml       # inherits base, no patches needed
    stg/kustomization.yaml       # patches cluster + values path
    prod/kustomization.yaml      # patches cluster + values path
```

The `root-apps.yaml` would point at `argocd-apps/overlays/dev`, rendered by Kustomize.

**Why it seemed good:** No ApplicationSets at all. Kustomize is a standard tool. Overlays are explicit about what changes per env.

**Why it was abandoned:** Scaling broke it. The values file path embeds the app name (`$values/apps/devops-test-webserver/stg/values.yaml`). Every new app requires a patch entry in every non-base overlay. For N apps × M envs you get N patch entries per overlay — still O(N) boilerplate, just in a different file. The user asked "how does it scale for multiple apps" and the answer was: not well.

**Secondary problem investigated:** Could Kustomize `helmCharts` be used so each app overlay is self-contained? This would remove the multi-source dependency and eliminate the app-name-in-path problem. However, the cluster routing problem (`destination.server`) remained unsolved without either config files per overlay or ArgoCD cluster secrets.

**Lesson:** Kustomize overlays are excellent for managing YAML that differs by environment. They are awkward when the "what differs" is structurally tied to data that doesn't cleanly map to YAML patches (like app name in a URL path). ApplicationSets were designed for exactly this class of problem.

---

## Decision 3: Single ApplicationSet, Matrix Generator

**Attempt:** One ApplicationSet using a matrix generator:

- **Generator 1:** `list` with env + cluster URL elements
- **Generator 2:** `git directories` on `apps/*` in repo-app-gitops

The matrix cross-products them. Template uses `{{env}}` from list and `{{path[1]}}` from git to construct app name, values path, and cluster destination.

```yaml
name: '{{env}}-{{path[1]}}'
valueFiles:
  - $values/apps/{{path[1]}}/{{env}}/values.yaml
destination:
  server: '{{cluster}}'
```

**Why it worked:** Adding a new app = add a directory under `apps/`. Adding a new env = add one element to the list. No AppSet changes for new apps. Template is self-contained and readable.

**Why Kustomize was ruled out:** The matrix approach solved the per-env duplication at the generator level, not the data level. No per-env config files, no per-env patches.

**This decision held.** The generator type evolved (list → cluster generator → git files), but the matrix + git directories pattern is the final architecture.

---

## Decision 4: Platform Team Owns All ArgoCD Config

**Problem identified:** The AppSet lived in `repo-app-gitops`, meaning the app team controlled deployment topology. If the platform team needed to rebuild infra or change cluster routing, they depended on the app team's repo.

**Decision:** Move the AppSet to `repo-platform-gitops`. The app team's repo becomes a pure data repo — values files only, zero ArgoCD YAML.

**Consequence:** `repo-app-gitops` has no `argocd-apps/` directory at all. The bootstrap `root-apps.yaml` (which pointed at `repo-app-gitops/argocd-apps`) was deleted. `platform-root` via `repo-platform-gitops` is the single entry point for everything.

**Why this is right:** Platform team can bootstrap an entire cluster — platform tools, app workloads, everything — by running Terraform and applying one YAML file (`root-app.yaml`). No dependency on any other team.

---

## Decision 5: Platform Tools Follow the Same AppSet Pattern

**Problem:** Platform tools (kube-prometheus-stack, metrics-server) were individual hardcoded Application files. They had no env separation — same config deployed to every cluster.

**Decision:** Apply the same matrix AppSet pattern to platform tools. Platform tools have a `config.yaml` per tool (chart identity: name, repoURL, targetRevision, namespace) and env-specific `values.yaml` files. A single `appset-platform.yaml` uses matrix(clusters × platform-apps/*/config.yaml) to deploy to all clusters.

**Why `config.yaml` here but not for apps:** App team apps all use the same generic Helm chart. Only the values differ per env. Platform tools each use a *different* external Helm chart with a different repo URL and chart name — chart identity is necessarily per-tool metadata, not per-env data. The `config.yaml` captures that identity once, not per env.

---

## Decision 6: Repo Split — platform-infra vs platform-gitops

**Observation:** `repo-platform` mixed two concerns: Terraform (how to provision the cluster) and ArgoCD configuration (what to run on the cluster). These have different change rates, different owners, and different risk profiles.

**Decision:** Split into:
- `repo-platform-infra` — Terraform, cluster provisioning, bootstrap seed (`root-app.yaml`)
- `repo-platform-gitops` — AppSets, platform tool configs, cluster registry

**Analogy to app team pattern:**
- `repo-app` = source code (infra equivalent: Terraform)
- `repo-app-gitops` = runtime config (infra equivalent: ArgoCD config in platform-gitops)

**Practical benefit:** A platform engineer can change what runs on a cluster (edit platform-gitops) without touching Terraform, and vice versa. Terraform changes are high-risk infra operations; GitOps changes are low-risk config operations.

---

## Decision 7: Cluster Routing — Three Approaches Considered

This was the most iterated decision in the entire session.

### Approach A: Hardcoded list in each AppSet (original)

```yaml
- list:
    elements:
      - env: dev
        cluster: https://kubernetes.default.svc
```

**Problem:** Duplicated in `appset-apps.yaml` AND `appset-platform.yaml`. Add a cluster → edit two files.

### Approach B: ArgoCD cluster generator with labeled secrets

Register clusters in ArgoCD with a `platform.io/env` label. Use the cluster generator — it auto-discovers all registered clusters.

```yaml
- clusters:
    selector:
      matchExpressions:
        - key: platform.io/env
          operator: Exists
```

Template uses `{{metadata.labels.platform\.io/env}}` for env name and `{{server}}` for cluster URL.

**Why abandoned:** The cluster secret lives only in Kubernetes. If accidentally deleted, it's gone until someone manually re-registers the cluster or re-runs Terraform. Additionally, the user made the correct observation: *the env name is not a credential*. There's no reason to hide it in a Kubernetes secret managed outside Git.

**Bug discovered here:** The original implementation used `platform.io/env: "true"` as the label value for all clusters (treating it as a presence indicator), then tried to read `{{metadata.labels.platform\.io/env}}` expecting the env name. This would return "true" for every cluster, not the actual env name. Fixed by switching to `matchExpressions: Exists` with the actual env name (`dev`, `stg`, `prod`) as the label value — but the approach was ultimately abandoned anyway.

### Approach C (final): Git files generator on `clusters/*.yaml`

```
clusters/
  dev.yaml    # env: dev, cluster: https://kubernetes.default.svc
  stg.yaml    # env: stg, cluster: https://kubernetes.stg.svc
  prod.yaml   # env: prod, cluster: https://kubernetes.prod.svc
```

Both AppSets point their first matrix generator at `clusters/*.yaml` from `repo-platform-gitops`.

**Why this is the right answer:**
- Single source of truth for cluster routing — defined once, consumed by both AppSets
- In Git — self-healing via ArgoCD, auditable, PR-reviewable
- Not a secret — cluster URLs are not credentials
- Adding a cluster = drop a file, both AppSets pick it up with zero AppSet changes
- Readable — open the file, immediately see which cluster and env it maps to

**The AppSets themselves became frozen policy** — they define *how* things deploy, not *where*. `clusters/` defines *where*. Orthogonal concerns, finally separated.

---

## Decision 8: Cluster Secret Management for External Clusters

**Context:** For dev (in-cluster), the ArgoCD cluster secret has no credentials — it just tells ArgoCD "the local cluster exists." For stg/prod (real external clusters), the secret contains actual kubeconfig tokens/certs.

**Considered:** External Secrets Operator (ESO) pointing at Vault or AWS Secrets Manager for stg/prod cluster credentials.

**Conclusion:** ESO is the right answer for stg/prod *when those clusters exist*. For the current single KIND dev cluster, a plain manifest in Git is correct. The `clusters/*.yaml` files in this repo are not secrets and don't require encryption.

**User's key insight:** "How is env cluster name a credential?" — it isn't. The URL and env name of a cluster are metadata, not secrets. Only the kubeconfig token/cert inside a cluster registration secret is sensitive, and that concern only applies to external clusters. Don't over-engineer for a problem that doesn't exist yet.

---

## Decision 9: Per-Cluster Resilience Controls

**Problem identified during lifecycle testing:** Five gaps found:

1. `targetRevision: HEAD` on the Helm chart — a breaking change to the chart repo hits all envs simultaneously
2. `prune: true` in prod — an accidental file deletion auto-deletes production workloads
3. No sync ordering — platform tools race against app workloads on bootstrap
4. No retry policy — transient failures leave apps stuck
5. Broken GitOps loop — CI `update-platform-manifests` step was fake (just `echo` statements)

**Decision:** All resilience controls that differ by env belong in `clusters/*.yaml`, not in the AppSet template. The AppSet reads `{{prune}}` and `{{helmChartRevision}}` from the cluster file and uses them directly. This keeps the AppSet as policy and the cluster file as env-specific configuration.

```yaml
# clusters/prod.yaml
helmChartRevision: "0.1.0"  # pinned — breaking chart changes can't reach prod
prune: false                 # manual review required before resources are deleted
```

```yaml
# clusters/dev.yaml
helmChartRevision: HEAD     # track latest — fast feedback
prune: true                 # auto-clean orphaned resources
```

**Sync waves:** Platform tools at `sync-wave: "-1"`, app workloads at `"0"`. On cluster bootstrap, ArgoCD ensures Prometheus and metrics-server are healthy before any application pod is scheduled.

**GitOps loop fix:** Implemented a real `update-gitops` CI job using `yq` to precisely update `image.tag` in the values file. Uses a dedicated `GITOPS_TOKEN` (PAT) to push to `repo-app-gitops` since `GITHUB_TOKEN` is scoped to the source repo only.

---

## What Was Deliberately Not Done

**Projects-AppSets Helm chart:** Attempted and reverted. The idea was to use a Helm chart that renders one ApplicationSet per project, so onboarding a new project (with its own gitops repo) only requires adding a line to `values.yaml`. While architecturally sound, it introduced a meta-layer (Helm rendering ArgoCD ApplicationSets) that adds complexity before it's needed. Revisit when a second project is actually onboarded.

**Sealed Secrets / ESO for cluster secrets:** Not implemented. The current cluster files contain no credentials. When real external clusters exist, implement ESO with the secrets manager of choice at that time.

**Ephemeral preview environments:** The PR generator AppSet pattern (creates a temporary environment per PR) was not implemented. The CI pipeline runs against dev on merge to main. Add a PR-based AppSet when the team needs pre-merge environment validation.

**ArgoCD Projects for RBAC:** All Applications are in the `default` project. When multiple teams are onboarded, create ArgoCD Projects to enforce namespace isolation and prevent cross-team access.
