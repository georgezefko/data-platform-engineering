#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root (directory where this script lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

mkdir -p "${REPO_ROOT}/.kube"

KIND_UP="${REPO_ROOT}/scripts/kind-up.sh"
TF_DIR="${REPO_ROOT}/infra/terraform/environments/dev"
ARGO_BOOTSTRAP="${REPO_ROOT}/argo/app-of-apps.yaml"

if [[ ! -x "${KIND_UP}" ]]; then
  echo "ERROR: kind-up script not found or not executable: ${KIND_UP}" >&2
  echo "Repo root: ${REPO_ROOT}" >&2
  echo "Contents of scripts/:" >&2
  ls -la "${REPO_ROOT}/scripts" || true
  exit 1
fi

bash "${KIND_UP}" development

pushd "${TF_DIR}" >/dev/null
terraform init
terraform apply -auto-approve
popd >/dev/null

kubectl apply -f "${ARGO_BOOTSTRAP}"
