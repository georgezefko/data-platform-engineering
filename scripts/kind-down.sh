#!/usr/bin/env bash
set -euo pipefail
CLUSTER_NAME="${1:-development}"
kind delete cluster --name "${CLUSTER_NAME}"
