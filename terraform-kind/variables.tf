variable "cluster_name" {
  type        = string
  description = "The name of the local Kind cluster."
  default     = "kind-local-01"
}

variable "github_auth_token" {
  type        = string
  description = "GitHub Auth Token (PAT) utilized to authenticate ArgoCD across all organizational Git repositories."
  sensitive   = true
}

variable "environment" {
  type        = string
  description = "The target environment to bootstrap (local, dev, stg, prod)."
  # kind clusters run the local env; "dev" bootstrapped a second root alongside
  # local on the same cluster.
  default = "local"
}

variable "authentik_github_client_id" {
  type        = string
  description = "Client ID of the GitHub OAuth app for Authentik login. Empty skips seeding it."
  default     = ""
}

variable "authentik_github_client_secret" {
  type        = string
  description = "Client secret of the GitHub OAuth app for Authentik login."
  default     = ""
  sensitive   = true
}

variable "gitops_ref" {
  description = "repo-platform-gitops git ref (branch, tag or SHA) that Terraform reads bootstrap config from"
  type        = string
  default     = "main"
}

variable "alert_slack_webhook" {
  type        = string
  description = "Slack incoming-webhook URL for Mimir Alertmanager notifications. Empty skips seeding it."
  default     = ""
  sensitive   = true
}

variable "grafana_git_sync" {
  description = "Manage the Grafana Git Sync repository. Set false on the first apply of a new cluster: the grafana-admin Secret only exists after Argo CD and External Secrets have synced."
  type        = bool
  default     = true
}
