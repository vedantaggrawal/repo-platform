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
  description = "The target environment to bootstrap (dev, stg, prod)."
  default     = "dev"
}

variable "github_oauth_client_id" {
  type        = string
  description = "GitHub OAuth App Client ID for ArgoCD SSO."
  sensitive   = true
}

variable "github_oauth_client_secret" {
  type        = string
  description = "GitHub OAuth App Client Secret for ArgoCD SSO."
  sensitive   = true
}

variable "github_org" {
  type        = string
  description = "GitHub organization name used for ArgoCD SSO team-based access control."
  default     = "vedantaggrawal"
}
