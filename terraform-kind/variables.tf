variable "cluster_name" {
  type        = string
  description = "The name of the local Kind cluster."
  default     = "devops-test"
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
