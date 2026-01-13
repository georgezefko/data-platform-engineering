variable "cluster_name" {
  description = "Name of the kind cluster"
  type        = string
  default     = "development"
}

variable "kind_config_path" {
  description = "Path to the kind cluster configuration file (relative to terraform directory)"
  type        = string
  default     = "../kind-config.yaml"
}

variable "argocd_namespace" {
  description = "Namespace for ArgoCD installation"
  type        = string
  default     = "argocd"
}

variable "argocd_version" {
  description = "Version of ArgoCD Helm chart"
  type        = string
  default     = "7.2.7"
}

variable "argocd_repo_url" {
  description = "ArgoCD Helm repository URL"
  type        = string
  default     = "https://argoproj.github.io/argo-helm"
}

variable "install_ingress_controller" {
  description = "Whether to install the NGINX ingress controller"
  type        = bool
  default     = true
}

variable "ingress_controller_version" {
  description = "Version of the ingress-nginx Helm chart"
  type        = string
  default     = "4.9.1"
}

variable "git_repo_url" {
  description = "Git repository URL for ArgoCD applications"
  type        = string
  default     = "https://github.com/georgezefko/kubernetes-roadmap.git"
}

variable "git_repo_branch" {
  description = "Git branch for ArgoCD applications"
  type        = string
  default     = "main"
}

variable "wait_for_argo" {
  description = "Whether to wait for ArgoCD to be ready before deploying applications"
  type        = bool
  default     = true
}

variable "argo_wait_timeout" {
  description = "Timeout in seconds to wait for ArgoCD to be ready"
  type        = number
  default     = 600
}

