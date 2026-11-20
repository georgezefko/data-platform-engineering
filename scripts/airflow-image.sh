#!/usr/bin/env bash
# Pull every image dev and prod run and load it into kind. kind doesn't pull from Artifact
# Registry: its tokens expire after an hour.
#  - Airflow: repository + tag from apps/airflow-helm/{dev,prod}/values.yaml (each env's own registry)
#  - Apps: their tags are hashes of the app folders, so they're computed from each ref the DAG
#    bundles track (main, sales-v1.2.0, ...), with that ref's own app_image.py and the env's
#    APPS_REGISTRY (unset in dev: app_image.py's default, dev's registry)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALUES="$REPO_ROOT/apps/airflow-helm/dev/values.yaml $REPO_ROOT/apps/airflow-helm/prod/values.yaml"
REGISTRY=us-central1-docker.pkg.dev
MONOREPO_URL=https://github.com/georgezefko/airflow-monorepo.git
CLONE="${TMPDIR:-/tmp}/airflow-monorepo.git"  # kept between runs, so only new commits are fetched

# Airflow: each env pulls from its own project's registry
images=$(awk '/^    repository:/ {r=$2} /^    tag:/ {print r ":" $2}' $VALUES)

[[ -d "$CLONE" ]] || git clone -q --bare "$MONOREPO_URL" "$CLONE"
git -C "$CLONE" fetch -q --prune origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'

# Apps: per env, each tracked ref's own app_image.py with that env's APPS_REGISTRY. Refs from
# before APPS_REGISTRY ignore it and print dev's names, which is also what their pods ask for.
for values in $VALUES; do
  reg=$(awk '/name: APPS_REGISTRY/ {getline; gsub(/["\047]/, "", $2); print $2; exit}' "$values")
  for ref in $(grep -o 'tracking_ref: [^,}]*' "$values" | awk '{print $2}' | sort -u); do
    tmp=$(mktemp -d)
    git -C "$CLONE" archive "$ref" teams | tar -x -C "$tmp"
    if [[ -f "$tmp/teams/platform/lib/app_image.py" ]]; then  # refs from before the apps have none
      # unset, not empty, in dev: an empty APPS_REGISTRY would give names with no registry
      images+=$'\n'$(env ${reg:+APPS_REGISTRY="$reg"} python3 "$tmp/teams/platform/lib/app_image.py" | awk '{print $2}')
    fi
    rm -rf "${tmp:?}"
  done
done

gcloud auth configure-docker "$REGISTRY" --quiet
for image in $(echo "$images" | sort -u); do
  for node in $(kind get nodes --name development); do
    if docker exec "$node" ctr --namespace=k8s.io images ls -q | grep -qxF "$image"; then
      echo "already loaded: $image"; continue
    fi
    docker pull -q "$image"
    # Not `kind load docker-image`: it imports --all-platforms, which fails on multi-arch
    # images when Docker's containerd store only pulled the local platform's layers.
    docker save "$image" | docker exec -i "$node" ctr --namespace=k8s.io images import --snapshotter=overlayfs -
  done
done