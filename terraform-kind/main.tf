resource "kind_cluster" "default" {
  name           = var.cluster_name
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
    }

    node {
      role = "worker"
    }
  }
}

# Core CD Engine deployed automatically upon cluster creation
resource "helm_release" "argocd" {
  name             = "argo-cd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "6.7.1"
  namespace        = "argocd"
  create_namespace = true

  depends_on = [kind_cluster.default]

  set {
    name  = "server.service.type"
    value = "NodePort"
  }
}

# Creates a global credential template granting ArgoCD access to any organizational repository
resource "kubernetes_secret" "repo_platform_creds" {
  metadata {
    name      = "github-org-credentials"
    namespace = helm_release.argocd.namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "repo-creds"
    }
  }

  data = {
    url      = "https://github.com/vedantaggrawal"
    username = "vedantaggrawal"
    password = var.github_auth_token
  }
}

# Automatically bootsrap the root GitOps mechanism via kubectl to seal the loop
resource "null_resource" "bootstrap_argocd" {
  depends_on = [helm_release.argocd, kubernetes_secret.repo_platform_creds]

  provisioner "local-exec" {
    command = "kind export kubeconfig --name ${var.cluster_name} && kubectl apply -f ../bootstrap/"
  }
}
