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
        host_port      = 30080
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = 443
        host_port      = 30443
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

# Cilium creates Grafana dashboard ConfigMaps in the monitoring namespace at install time.
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [kind_cluster.default]
}

# Prometheus Operator CRDs must exist before Cilium can create ServiceMonitor resources.
resource "null_resource" "prometheus_operator_crds" {
  depends_on = [kind_cluster.default]

  provisioner "local-exec" {
    command = "kind export kubeconfig --name ${var.cluster_name} && kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.82.0/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml"
  }
}

# CNI must be installed before the cluster becomes Ready and before any workloads
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.19.3"
  namespace  = "kube-system"

  depends_on = [kind_cluster.default, null_resource.prometheus_operator_crds, kubernetes_namespace.monitoring]

  set {
    name  = "k8sServiceHost"
    value = "${var.cluster_name}-control-plane"
  }

  set {
    name  = "k8sServicePort"
    value = "6443"
  }

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

  # Ingress only. Login is the local admin until Argo CD moves to Authentik (OIDC).
  values = [
    yamlencode({
      global = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "128Mi"
          }
          limits = {
            memory = "128Mi"
          }
        }
      }
      controller = {
        resources = {
          requests = {
            cpu    = "100m"
            memory = "768Mi"
          }
          limits = {
            memory = "1536Mi"
          }
        }
      }
      repoServer = {
        # 512Mi OOMKilled when every app re-rendered after a controller restart.
        resources = {
          requests = {
            cpu    = "100m"
            memory = "1Gi"
          }
          limits = {
            memory = "1Gi"
          }
        }
      }
      applicationSet = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "128Mi"
          }
          limits = {
            memory = "128Mi"
          }
        }
      }
      server = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "128Mi"
          }
          limits = {
            memory = "128Mi"
          }
        }
        # Trust the platform CA so OIDC discovery to Authentik verifies. Secret
        # platform-ca is delivered by ESO (repo-platform-gitops, secret-stores);
        # optional, because Terraform installs Argo CD before ESO exists.
        env = [{
          name  = "SSL_CERT_DIR"
          value = "/etc/ssl/certs:/etc/platform-ca"
        }]
        volumes = [{
          name = "platform-ca"
          secret = {
            secretName = "platform-ca"
            optional   = true
          }
        }]
        volumeMounts = [{
          name      = "platform-ca"
          mountPath = "/etc/platform-ca"
          readOnly  = true
        }]
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
      # No Dex: Argo CD gets OIDC from Authentik directly.
      dex = {
        enabled = false
      }
      # notifications-controller takes --logformat from a chart-level value,
      # not the params CM (its hard-coded CLI arg overrides the env).
      notifications = {
        logFormat = "json"
      }
      configs = {
        params = {
          "server.insecure"                       = "true"
          # JSON logs for the remaining ArgoCD components so Loki's
          # | json parser unpacks fields cleanly. Key names match the
          # env-var bindings the chart wires per component (note:
          # repo-server uses `reposerver.log.format`, not `repo.server`).
          "server.log.format"                     = "json"
          "reposerver.log.format"                 = "json"
          "controller.log.format"                 = "json"
          "applicationsetcontroller.log.format"   = "json"
          # Cap concurrent manifest generations so a reconcile storm queues
          # instead of exhausting repo-server memory (0 = unlimited).
          "reposerver.parallelism.limit" = "4"
        }
        cm = {
          # Base URL Argo CD advertises (SSO callbacks, links). Must match what
          # the browser hits (kind maps container 443 -> host 30443). It belongs
          # in argocd-cm; `server.url` under params is not a valid key.
          "url" = "https://local.argocd.internal:30443"
          # SSO via Authentik (public client `argocd`, PKCE; GitHub login is
          # federated there). Groups arrive in the `profile` scope. The local
          # admin stays as break-glass.
          "oidc.config" = yamlencode({
            name                     = "Authentik"
            issuer                   = "https://local.authentik.internal:30443/application/o/argocd/"
            clientID                 = "argocd"
            enablePKCEAuthentication = true
            requestedScopes          = ["openid", "profile", "email"]
          })
        }
        rbac = {
          # Deny by default; members of Authentik group platform-admins are admins.
          "policy.default" = ""
          "policy.csv"     = "g, platform-admins, role:admin"
          "scopes"         = "[groups]"
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
