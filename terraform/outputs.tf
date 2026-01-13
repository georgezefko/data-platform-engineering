output "cluster_name" {
  description = "Name of the kind cluster"
  value       = var.cluster_name
}

output "kubectl_context" {
  description = "Kubectl context to use for the cluster"
  value       = "kind-${var.cluster_name}"
}

output "argocd_namespace" {
  description = "Namespace where ArgoCD is installed"
  value       = var.argocd_namespace
}

output "argocd_server_port_forward_command" {
  description = "Command to port-forward ArgoCD server"
  value       = "kubectl port-forward svc/argocd-server -n ${var.argocd_namespace} 8080:80 --context kind-${var.cluster_name}"
}

output "get_argocd_admin_password_command" {
  description = "Command to get ArgoCD admin password"
  value       = "kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d --context kind-${var.cluster_name}"
}

output "argocd_server_url" {
  description = "ArgoCD server URL (after port-forward)"
  value       = "http://localhost:8080"
}

