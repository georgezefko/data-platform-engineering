#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLUSTER_NAME="${1:-development}"
TF_DIR="${REPO_ROOT}/infra/terraform/environments/dev"
KUBE_DIR="${REPO_ROOT}/.kube"

echo "Resetting local environment..."
echo "Cluster: ${CLUSTER_NAME}"
echo "Terraform dir: ${TF_DIR}"
echo "Kube dir: ${KUBE_DIR}"
echo

# Delete kind cluster (ignore if it doesn't exist)
kind delete cluster --name "${CLUSTER_NAME}" || true

# Remove local terraform state (only if you use local backend)
if [[ -d "${TF_DIR}" ]]; then
  rm -rf "${TF_DIR}/.terraform" || true
  rm -f "${TF_DIR}/.terraform.lock.hcl" || true
  rm -f "${TF_DIR}/terraform.tfstate" || true
  rm -f "${TF_DIR}/terraform.tfstate.backup" || true
fi

# Remove repo kubeconfig
rm -rf "${KUBE_DIR}" || true

echo "Done."
echo "Next: make up"