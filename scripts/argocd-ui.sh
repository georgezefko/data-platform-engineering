#!/usr/bin/env bash
set -euo pipefail

NS="argocd"
SVC="argocd-server"
LOCAL_PORT="${1:-8081}"

echo "Argo CD UI: http://localhost:${LOCAL_PORT}"
echo "Username: admin"
echo -n "Password: "
kubectl -n "${NS}" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo
echo
echo "Starting port-forward..."
exec kubectl -n "${NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:80"