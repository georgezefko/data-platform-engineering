resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"

  # Pin later if you want; leaving unpinned is OK for local dev, but pinning is better.
  # version = "x.y.z"

  values = [yamlencode({
    server = {
      service = {
        type = "ClusterIP"
      }
    }
    configs = {
      cm = {
        url = "https://${var.argocd_host}"
      }
    }
  })]
}

# --- Self-signed TLS for argo.dev.com ---
resource "tls_private_key" "argocd" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "argocd" {
  private_key_pem = tls_private_key.argocd.private_key_pem

  subject {
    common_name  = var.argocd_host
    organization = var.argocd_host
  }

  validity_period_hours = 365 * 24
  early_renewal_hours   = 30 * 24

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  # Helps with modern browsers/clients
  dns_names = [var.argocd_host]
}

resource "kubernetes_secret_v1" "argocd_tls" {
  metadata {
    name      = "argocd-tls"
    namespace = var.argocd_namespace
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = tls_self_signed_cert.argocd.cert_pem
    "tls.key" = tls_private_key.argocd.private_key_pem
  }

  depends_on = [helm_release.argocd]
}

# --- Ingress for Argo CD ---
resource "kubernetes_ingress_v1" "argocd" {
  metadata {
    name      = "argocd-ingress"
    namespace = var.argocd_namespace
    annotations = {
      "nginx.ingress.kubernetes.io/ssl-redirect"      = "true"
      "nginx.ingress.kubernetes.io/backend-protocol" = "HTTPS"
    }
  }

  spec {
    ingress_class_name = "nginx"

    tls {
      hosts       = [var.argocd_host]
      secret_name = kubernetes_secret_v1.argocd_tls.metadata[0].name
    }

    rule {
      host = var.argocd_host

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "argocd-server"
              port {
                number = 443
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_secret_v1.argocd_tls]
}