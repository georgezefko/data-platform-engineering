# Configure Kubernetes provider
# This will use the kubeconfig from the kind cluster
provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "kind-${var.cluster_name}"
}

# Configure Helm provider
provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "kind-${var.cluster_name}"
  }
}

# Create kind cluster using null_resource
resource "null_resource" "kind_cluster" {
  triggers = {
    cluster_name     = var.cluster_name
    kind_config_path = var.kind_config_path
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Resolve config path (relative to terraform directory)
      CONFIG_PATH="${path.root}/${var.kind_config_path}"
      if [ ! -f "$CONFIG_PATH" ]; then
        echo "Error: Kind config file not found at $CONFIG_PATH"
        exit 1
      fi
      
      # Check if cluster already exists
      if kind get clusters | grep -q "^${var.cluster_name}$"; then
        echo "Cluster ${var.cluster_name} already exists, skipping creation"
      else
        echo "Creating kind cluster ${var.cluster_name}..."
        kind create cluster --name ${var.cluster_name} --config "$CONFIG_PATH"
        echo "Waiting for cluster to be ready..."
        kubectl wait --for=condition=Ready nodes --all --timeout=300s --context kind-${var.cluster_name}
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      if kind get clusters | grep -q "^${var.cluster_name}$"; then
        echo "Deleting kind cluster ${var.cluster_name}..."
        kind delete cluster --name ${var.cluster_name}
      fi
    EOT
  }
}

# Create namespaces
resource "kubernetes_namespace" "argocd" {
  depends_on = [null_resource.kind_cluster]

  metadata {
    name = var.argocd_namespace
  }
}

resource "kubernetes_namespace" "develop" {
  depends_on = [null_resource.kind_cluster]

  metadata {
    name = "develop"
  }
}

resource "kubernetes_namespace" "monitoring" {
  depends_on = [null_resource.kind_cluster]

  metadata {
    name = "monitoring"
  }
}

# Add ArgoCD Helm repository
resource "helm_release" "argocd" {
  depends_on = [
    null_resource.kind_cluster,
    kubernetes_namespace.argocd
  ]

  name       = "argocd"
  repository = var.argocd_repo_url
  chart      = "argo-cd"
  version    = var.argocd_version
  namespace  = var.argocd_namespace

  values = [
    yamlencode({
      server = {
        service = {
          type = "NodePort"
        }
        ingress = {
          enabled = false
        }
      }
    })
  ]

  wait = var.wait_for_argo
  timeout = var.argo_wait_timeout
}

# Wait for ArgoCD to be ready
resource "null_resource" "wait_for_argocd" {
  depends_on = [helm_release.argocd]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for ArgoCD CRDs to be available..."
      kubectl wait --for condition=established --timeout=${var.argo_wait_timeout}s crd/applications.argoproj.io --context kind-${var.cluster_name} || true
      
      echo "Waiting for ArgoCD deployments to be ready..."
      kubectl wait --for=condition=available --timeout=${var.argo_wait_timeout}s deployment/argocd-server -n ${var.argocd_namespace} --context kind-${var.cluster_name} || true
      kubectl wait --for=condition=available --timeout=${var.argo_wait_timeout}s deployment/argocd-repo-server -n ${var.argocd_namespace} --context kind-${var.cluster_name} || true
      kubectl wait --for=condition=available --timeout=${var.argo_wait_timeout}s deployment/argocd-application-controller -n ${var.argocd_namespace} --context kind-${var.cluster_name} || true
      
      echo "ArgoCD is ready!"
    EOT
  }
}

# Install NGINX Ingress Controller (optional)
resource "helm_release" "ingress_nginx" {
  count = var.install_ingress_controller ? 1 : 0

  depends_on = [null_resource.kind_cluster]

  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.ingress_controller_version
  namespace  = "ingress-nginx"

  create_namespace = true

  values = [
    yamlencode({
      controller = {
        service = {
          type = "NodePort"
        }
      }
    })
  ]
}

# Apply ClusterRoleBinding for ArgoCD
resource "kubernetes_manifest" "argocd_cluster_role_binding" {
  depends_on = [null_resource.wait_for_argocd]

  manifest = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name = "argocd-application-controller-binding"
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "argocd-applicationset-controller"
    }
    subjects = [
      {
        kind      = "ServiceAccount"
        name      = "argocd-application-controller"
        namespace = var.argocd_namespace
      }
    ]
  }
}

# Deploy ArgoCD Applications
resource "kubernetes_manifest" "argocd_applications" {
  depends_on = [
    null_resource.wait_for_argocd,
    kubernetes_manifest.argocd_cluster_role_binding
  ]

  for_each = {
    kafka           = "${path.module}/../argo-apps/kafka-application.yaml"
    postgres        = "${path.module}/../argo-apps/postgress-application.yaml"
    zookeeper       = "${path.module}/../argo-apps/zookeeper-application.yaml"
    schema_registry = "${path.module}/../argo-apps/schema-registry-application.yaml"
    mage_helm       = "${path.module}/../argo-apps/mage-helm-application.yaml"
    mage_no_helm    = "${path.module}/../argo-apps/mage-no-helm-application.yaml"
    grafana         = "${path.module}/../argo-apps/grafana-application.yaml"
    prometheus      = "${path.module}/../argo-apps/prometheus-application.yaml"
  }

  manifest = yamldecode(file(each.value))
}

