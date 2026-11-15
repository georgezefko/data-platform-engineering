#!/usr/bin/env bash
# Pull the Airflow image built by airflow-monorepo CI and load it into kind.
# Usage: airflow-image.sh [tag]   No tag: every tag used in apps/airflow-helm/{dev,prod}/values.yaml.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY=us-central1-docker.pkg.dev
IMAGE=$REGISTRY/project-09344e23-c1cd-49df-a40/airflow-monorepo/airflow

if [[ $# -gt 0 && -n "$1" ]]; then
  TAGS="$1"
else
  TAGS=$(awk '/^    tag:/ {print $2}' "$REPO_ROOT/apps/airflow-helm/dev/values.yaml" "$REPO_ROOT/apps/airflow-helm/prod/values.yaml" | sort -u)
fi

gcloud auth configure-docker "$REGISTRY" --quiet
for tag in $TAGS; do
  docker pull "$IMAGE:$tag"
  # Not `kind load docker-image`: it imports --all-platforms, which fails on multi-arch
  # images when Docker's containerd store only pulled the local platform's layers.
  for node in $(kind get nodes --name development); do
    docker save "$IMAGE:$tag" | docker exec -i "$node" ctr --namespace=k8s.io images import --snapshotter=overlayfs -
  done
done
