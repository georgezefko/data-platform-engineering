#!/usr/bin/env bash
# Apply the app-of-apps, optionally limited to some apps so the kind node isn't overloaded.
# Usage: argo-apps.sh [name ...]   Names match argo/apps/*<name>*.yaml, e.g. postgres airflow-dev.
#                                  No names: every app.
# Dependencies are not resolved for you: airflow-* needs postgres; kafka-connect needs
# kafka, zookeeper and postgres; starrocks reads from kafka.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -eq 0 ]]; then
  kubectl apply -f "$REPO_ROOT/argo/app-of-apps.yaml"
  # null removes the filter; plain `kubectl apply` would keep a filter set earlier
  kubectl -n argocd patch application apps --type merge -p '{"spec":{"source":{"directory":null}}}'
  exit 0
fi

globs=()
for name in "$@"; do
  compgen -G "$REPO_ROOT/argo/apps/*${name}*.yaml" >/dev/null || { echo "No app matches '$name' in argo/apps/" >&2; exit 1; }
  globs+=("*${name}*.yaml")
done
include="{$(IFS=,; echo "${globs[*]}")}"
kubectl apply -f "$REPO_ROOT/argo/app-of-apps.yaml"
kubectl -n argocd patch application apps --type merge \
  -p "{\"spec\":{\"source\":{\"directory\":{\"include\":\"$include\"}}}}"
echo "Enabled: $(cd "$REPO_ROOT/argo/apps" && ls $(printf '*%s*.yaml ' "$@") | sort -u | tr '\n' ' ')"
