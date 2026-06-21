resource "kind_cluster" "default" {
  name           = var.cluster_name
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    networking {
      disable_default_cni = true    # Cilium will be installed as the CNI
      kube_proxy_mode     = "none"  # Cilium replaces kube-proxy via eBPF
    }

    node {
      role = "control-plane"

      # Expose host ports for Cilium ingress controller (hostNetwork mode)
      extra_port_mappings {
        container_port = 80
        host_port      = 10080
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = 443
        host_port      = 10443
        protocol       = "TCP"
      }

      kubeadm_config_patches = [
        <<-EOT
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
        EOT
      ]
    }

    node {
      role = "worker"
    }
  }
}

# Gateway API CRDs must exist before Cilium can enable gatewayAPI.
# No official Helm chart exists; CRDs are distributed as raw YAML from GitHub releases.
resource "null_resource" "gateway_api_crds" {
  depends_on = [kind_cluster.default]

  provisioner "local-exec" {
    command = "kind export kubeconfig --name ${var.cluster_name} && kubectl apply --server-side --force-conflicts -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml"
  }
}

# CNI must be installed before the cluster becomes Ready and before any workloads
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.19.3"
  namespace  = "kube-system"

  depends_on = [kind_cluster.default, null_resource.gateway_api_crds]

  values = [file("../../repo-platform-gitops/platform-apps/cilium/local/values.yaml")]
}

# Core CD Engine deployed automatically upon cluster creation
resource "helm_release" "argocd" {
  name             = "argo-cd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "6.7.1"
  namespace        = "argocd"
  create_namespace = true

  depends_on = [kind_cluster.default, helm_release.cilium]

  # --- GitHub SSO via Dex + Ingress ---

  values = [
    yamlencode({
      server = {
        service = {
          type = "ClusterIP"
        }
        ingress = {
          enabled          = true
          ingressClassName = "cilium"
          hostname         = "local.argocd.internal"
          annotations = {
            "cert-manager.io/cluster-issuer" = "selfsigned"
          }
          tls = true
        }
      }
      # notifications-controller takes --logformat from a chart-level value,
      # not the params CM (its hard-coded CLI arg overrides the env).
      notifications = {
        logFormat = "json"
      }
      configs = {
        params = {
          "server.url"                            = "https://local.argocd.internal:10443"
          "server.insecure"                       = "true"
          # JSON logs for the remaining ArgoCD components so Loki's
          # | json parser unpacks fields cleanly. Key names match the
          # env-var bindings the chart wires per component (note:
          # repo-server uses `reposerver.log.format`, not `repo.server`).
          "server.log.format"                     = "json"
          "reposerver.log.format"                 = "json"
          "controller.log.format"                 = "json"
          "applicationsetcontroller.log.format"   = "json"
        }
        cm = {
          "dex.config" = yamlencode({
            connectors = [{
              type = "github"
              id   = "github"
              name = "GitHub"
              config = {
                clientID     = "$dex.github.clientId"
                clientSecret = "$dex.github.clientSecret"
                orgs = [{
                  name = var.github_org
                }]
              }
            }]
          })
        }
        secret = {
          extra = {
            "dex.github.clientId"     = var.github_oauth_client_id
            "dex.github.clientSecret" = var.github_oauth_client_secret
          }
        }
        rbac = {
          "policy.default" = "role:readonly"
          "policy.csv"     = "g, ${var.github_org}:admin, role:admin"
        }
      }
    })
  ]
}

# Pre-create the app namespace so the image pull secret exists before ArgoCD first syncs
resource "kubernetes_namespace" "devops_test_webserver" {
  metadata {
    name = "devops-test-webserver"
  }

  depends_on = [kind_cluster.default]
}

# Image pull secret for ghcr.io — matches the imagePullSecrets reference in app values
resource "kubernetes_secret" "ghcr_pull_secret" {
  metadata {
    name      = "ghcr-pull-secret"
    namespace = kubernetes_namespace.devops_test_webserver.metadata[0].name
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "ghcr.io" = {
          username = "vedantaggrawal"
          password = var.github_auth_token
          auth     = base64encode("vedantaggrawal:${var.github_auth_token}")
        }
      }
    })
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

# cert-manager for automatic TLS certificate provisioning
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.17.2"
  namespace        = "cert-manager"
  create_namespace = true

  depends_on = [kind_cluster.default, helm_release.cilium]

  set {
    name  = "crds.enabled"
    value = "true"
  }

  # JSON logs for cert-manager controller, webhook, cainjector.
  set {
    name  = "extraArgs[0]"
    value = "--logging-format=json"
  }
  set {
    name  = "webhook.extraArgs[0]"
    value = "--logging-format=json"
  }
  set {
    name  = "cainjector.extraArgs[0]"
    value = "--logging-format=json"
  }
}

# Self-signed ClusterIssuer for local dev TLS
resource "null_resource" "self_signed_issuer" {
  depends_on = [helm_release.cert_manager]

  provisioner "local-exec" {
    command = <<-EOT
      kind export kubeconfig --name ${var.cluster_name}
      kubectl apply -f - <<EOF
      apiVersion: cert-manager.io/v1
      kind: ClusterIssuer
      metadata:
        name: selfsigned
      spec:
        selfSigned: {}
      EOF
    EOT
  }
}

# Automatically bootsrap the root GitOps mechanism via kubectl to seal the loop
resource "null_resource" "bootstrap_argocd" {
  depends_on = [helm_release.argocd, kubernetes_secret.repo_platform_creds, kubernetes_secret.ghcr_pull_secret]

  provisioner "local-exec" {
    command = "kind export kubeconfig --name ${var.cluster_name} && kubectl apply -f ../../repo-platform-gitops/bootstrap/${var.environment}.yaml"
  }
}
