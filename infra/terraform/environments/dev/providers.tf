variable "kubeconfig_path" {
  type    = string
  default = "/home/vscode/.kube/config"
}

variable "kube_context" {
  type    = string
  default = "kind-development"
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}
