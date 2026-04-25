#!/usr/bin/env bash
set -euo pipefail

NS="develop"
SERVICE="postgres"
PORT=5432

echo "Mage DB → http://localhost:${PORT}"
exec kubectl -n "${NS}" port-forward "svc/${SERVICE}" "${PORT}:${PORT}"