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
