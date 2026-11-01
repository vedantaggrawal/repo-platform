# Grafana Git Sync: Grafana pulls dashboards from the gitops repo and turns UI
# edits into pull requests. The repository object lives in Grafana's own API, so
# Terraform (not Argo) owns it. It reuses the Argo CD repo PAT: same repo, same
# permissions; nothing new to seed.
#
# Webhooks are not registered: GitHub cannot reach a laptop cluster, so Grafana
# polls instead (interval below). Add `webhook { base_url = ... }` on a hosted env.

# No depends_on here: a data source that waits on the Argo release is deferred to apply time whenever
# that release has a planned change, the provider below then runs with an unknown (empty) auth, and
# provider 4.52 sends the request unauthenticated (401, 2026-10-31). Bootstrap ordering is a variable:
# the Secret is created by Argo CD + ESO, so the first apply of a new cluster sets grafana_git_sync=false.
data "kubernetes_secret" "grafana_admin" {
  count = var.grafana_git_sync ? 1 : 0
  metadata {
    name      = "grafana-admin"
    namespace = "monitoring"
  }
}

provider "grafana" {
  url  = "https://local.grafana.internal:30443"
  auth = try("${data.kubernetes_secret.grafana_admin[0].data["admin-user"]}:${data.kubernetes_secret.grafana_admin[0].data["admin-password"]}", "bootstrap:disabled")
  # The gateway serves the platform's private CA; Terraform runs on the laptop.
  insecure_skip_verify = true
}

resource "grafana_apps_provisioning_repository_v0alpha1" "platform_dashboards" {
  count = var.grafana_git_sync ? 1 : 0
  metadata {
    uid = "platform-dashboards"
  }
  spec {
    title       = "platform-dashboards"
    description = "Dashboards in gitops; UI edits open pull requests"
    type        = "github"
    # branch only: every UI edit becomes a PR, nothing lands on main unreviewed.
    workflows = ["branch"]
    sync {
      enabled          = true
      target           = "folder"
      interval_seconds = 60
    }
    github {
      url    = "https://github.com/vedantaggrawal/repo-platform-gitops"
      branch = "main"
      path   = "platform-apps/grafana/local/dashboards"
    }
  }
  secure {
    token = {
      create = var.github_auth_token
    }
  }
  secure_version = 1
}
