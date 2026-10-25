# Human-issued credentials (from your tfvars, never git) seeded into the cluster.
# A PushSecret in repo-platform-gitops (manifests/secret-stores) copies each one
# into OpenBao, where ESO delivers it to the app. A rebuild needs no hand steps.

resource "kubernetes_namespace" "platform_seed" {
  metadata {
    name = "platform-seed"
  }

  depends_on = [kind_cluster.default]
}

# GitHub OAuth app for "Log in with GitHub" in Authentik. Its callback is
# https://local.authentik.internal:30443/source/oauth/callback/github/
resource "kubernetes_secret" "authentik_github_oauth" {
  count = var.authentik_github_client_id != "" && var.authentik_github_client_secret != "" ? 1 : 0

  metadata {
    name      = "authentik-github-oauth"
    namespace = kubernetes_namespace.platform_seed.metadata[0].name
  }

  data = {
    client_id     = var.authentik_github_client_id
    client_secret = var.authentik_github_client_secret
  }
}

# Slack incoming webhook for Mimir Alertmanager. Alertmanager reads it from a
# file (api_url_file), so the URL never appears in config.
resource "kubernetes_secret" "alert_slack" {
  count = var.alert_slack_webhook != "" ? 1 : 0

  metadata {
    name      = "alert-slack"
    namespace = kubernetes_namespace.platform_seed.metadata[0].name
  }

  data = {
    webhook_url = var.alert_slack_webhook
  }
}
