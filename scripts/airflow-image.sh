#!/usr/bin/env bash
# Pull every image dev and prod run and load it into kind. kind doesn't pull from Artifact
# Registry: its tokens expire after an hour.
#  - Airflow: every images.airflow.tag in apps/airflow-helm/{dev,prod}/values.yaml
#  - Apps: their tags are hashes of the app folders, so they're computed from each ref the DAG
#    bundles track (main, sales-v1.2.0, ...), with that ref's own app_image.py
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALUES="$REPO_ROOT/apps/airflow-helm/dev/values.yaml $REPO_ROOT/apps/airflow-helm/prod/values.yaml"
REGISTRY=us-central1-docker.pkg.dev
MONOREPO_URL=https://github.com/georgezefko/airflow-monorepo.git
CLONE="${TMPDIR:-/tmp}/airflow-monorepo.git"  # kept between runs, so only new commits are fetched

images=$(awk -v img="$REGISTRY/project-09344e23-c1cd-49df-a40/airflow-monorepo/airflow" '/^    tag:/ {print img ":" $2}' $VALUES)

[[ -d "$CLONE" ]] || git clone -q --bare "$MONOREPO_URL" "$CLONE"
git -C "$CLONE" fetch -q --prune origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
for ref in $(grep -ho 'tracking_ref: [^,}]*' $VALUES | awk '{print $2}' | sort -u); do
  tmp=$(mktemp -d)
  git -C "$CLONE" archive "$ref" teams | tar -x -C "$tmp"
  if [[ -f "$tmp/teams/platform/lib/app_image.py" ]]; then  # refs from before the apps have none
    images+=$'\n'$(python3 "$tmp/teams/platform/lib/app_image.py" | awk '{print $2}')
  fi
  rm -rf "${tmp:?}"
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