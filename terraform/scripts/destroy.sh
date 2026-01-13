#!/bin/bash

# Script to destroy Kubernetes infrastructure using Terraform

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(dirname "$SCRIPT_DIR")"

cd "$TERRAFORM_DIR"

echo "🗑️  Destroying Terraform infrastructure..."

# Confirm deletion
read -p "Are you sure you want to destroy all resources? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

# Destroy Terraform resources
terraform destroy

echo ""
echo "✅ Infrastructure destroyed!"
echo ""

