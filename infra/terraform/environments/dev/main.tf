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
  })]
}
