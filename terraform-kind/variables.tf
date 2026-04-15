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
