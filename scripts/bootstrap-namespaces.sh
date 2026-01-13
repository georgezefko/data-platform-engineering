#!/usr/bin/env bash
set -euo pipefail

for ns in argocd mage kafka; do
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns"
done

kubectl get ns | egrep 'argocd|mage|kafka'