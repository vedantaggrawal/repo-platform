# Grafana Git Sync: Grafana pulls dashboards from the gitops repo and turns UI
# edits into pull requests. The repository object lives in Grafana's own API, so
# Terraform (not Argo) owns it. It reuses the Argo CD repo PAT: same repo, same
# permissions; nothing new to seed.
#
# Webhooks are not registered: GitHub cannot reach a laptop cluster, so Grafana
# polls instead (interval below). Add `webhook { base_url = ... }` on a hosted env.

data "kubernetes_secret" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = "monitoring"
  }
  depends_on = [helm_release.argocd]
}

provider "grafana" {
  url  = "https://local.grafana.internal:30443"
  auth = "${data.kubernetes_secret.grafana_admin.data["admin-user"]}:${data.kubernetes_secret.grafana_admin.data["admin-password"]}"
  # The gateway serves the platform's private CA; Terraform runs on the laptop.
  insecure_skip_verify = true
}

resource "grafana_apps_provisioning_repository_v0alpha1" "platform_dashboards" {
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
