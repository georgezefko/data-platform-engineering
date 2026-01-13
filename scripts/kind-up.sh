#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root as the parent of the scripts directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLUSTER_NAME="${1:-development}"
KIND_CFG="${KIND_CFG:-${REPO_ROOT}/infra/kind/kind-config.yaml}"

echo "Repo root: ${REPO_ROOT}"
echo "Using kind config: ${KIND_CFG}"

if [[ ! -f "${KIND_CFG}" ]]; then
  echo "ERROR: kind config not found at: ${KIND_CFG}" >&2
  exit 1
fi

if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "kind cluster '${CLUSTER_NAME}' already exists"
else
  kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CFG}"
fi

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
kubectl get nodes -o wide
