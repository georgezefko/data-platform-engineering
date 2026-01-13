#!/bin/bash

# Script to deploy Kubernetes infrastructure using Terraform

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(dirname "$SCRIPT_DIR")"

cd "$TERRAFORM_DIR"

echo "🚀 Starting Terraform deployment..."

# Check if terraform is installed
if ! command -v terraform &> /dev/null; then
    echo "❌ Terraform is not installed. Please install it first."
    exit 1
fi

# Check if kind is installed
if ! command -v kind &> /dev/null; then
    echo "❌ kind is not installed. Please install it first."
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed. Please install it first."
    exit 1
fi

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    echo "❌ helm is not installed. Please install it first."
    exit 1
fi

# Initialize Terraform if needed
if [ ! -d ".terraform" ]; then
    echo "📦 Initializing Terraform..."
    terraform init
fi

# Apply Terraform configuration
echo "🔧 Applying Terraform configuration..."
terraform apply

# Get outputs
echo ""
echo "✅ Deployment complete!"
echo ""
echo "📋 Next steps:"
echo ""
echo "1. Get ArgoCD admin password:"
echo "   $(terraform output -raw get_argocd_admin_password_command)"
echo ""
echo "2. Port-forward ArgoCD server:"
echo "   $(terraform output -raw argocd_server_port_forward_command)"
echo ""
echo "3. Access ArgoCD UI at: $(terraform output -raw argocd_server_url)"
echo "   Username: admin"
echo "   Password: (from step 1)"
echo ""
echo "4. Check ArgoCD applications:"
echo "   kubectl get applications -n argocd --context $(terraform output -raw kubectl_context)"
echo ""

