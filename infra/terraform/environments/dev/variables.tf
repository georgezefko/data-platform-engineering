# variable "argocd_host" {
#   type    = string
#   default = "argo.dev.com"
# }

variable "argocd_namespace" {
  type    = string
  default = "argocd"
}

variable "kubeconfig_path" {
  type    = string
  default = "/home/vscode/.kube/config"
}

variable "kube_context" {
  type    = string
  default = "kind-development"
}