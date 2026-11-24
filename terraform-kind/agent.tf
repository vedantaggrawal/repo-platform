# Read-only API credentials for the in-cluster agent's MCP servers (repo-platform-gitops manifests/opencode).
# Tokens live in Terraform state and in Secrets in namespace opencode; never in git.

# Grafana: a service account with role Viewer (dashboards, Explore queries on Mimir/Loki/Tempo; no edits).
resource "grafana_service_account" "eve_agent" {
  count = var.grafana_git_sync ? 1 : 0
  name  = "eve-agent"
  role  = "Viewer"
}

resource "grafana_service_account_token" "eve_agent" {
  count              = var.grafana_git_sync ? 1 : 0
  name               = "mcp-grafana"
  service_account_id = grafana_service_account.eve_agent[0].id
}

resource "kubernetes_secret" "mcp_grafana_token" {
  count = var.grafana_git_sync ? 1 : 0
  metadata {
    name      = "mcp-grafana-token"
    namespace = "opencode"
  }
  data = {
    token = one(grafana_service_account_token.eve_agent[*].key)
  }
}

# Gitea: a token with read scopes only (issues, repositories, users, orgs). It belongs to the local
# admin because Gitea mints tokens for the authenticated user; the scopes make it read-only.
data "kubernetes_secret" "gitea_admin" {
  metadata {
    name      = "gitea-admin"
    namespace = "gitea"
  }
}

provider "gitea" {
  base_url = "https://gitea.local.evelab.space:30443"
  username = data.kubernetes_secret.gitea_admin.data["username"]
  password = data.kubernetes_secret.gitea_admin.data["password"]
}

resource "gitea_token" "eve_agent" {
  name   = "eve-agent-readonly"
  scopes = ["read:issue", "read:repository", "read:user", "read:organization"]
}

resource "kubernetes_secret" "mcp_gitea_token" {
  metadata {
    name      = "mcp-gitea-token"
    namespace = "opencode"
  }
  data = {
    token = gitea_token.eve_agent.token
  }
}
