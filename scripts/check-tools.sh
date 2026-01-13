#!/usr/bin/env bash
set -euo pipefail

echo "Tool versions:"
kind --version
kubectl version --client=true
helm version
kustomize version
terraform version | head -n 1
jq --version || true
yq --version || true

echo
echo "Docker info (for kind):"
docker version
docker info >/dev/null
echo "OK"

#is script doesnt work make it executable chmod +x scripts/check-tools.sh