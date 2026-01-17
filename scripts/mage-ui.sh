#!/usr/bin/env bash
set -euo pipefail

NS="develop"
SERVICE="mageai"
PORT=6789

echo "Mage UI → http://localhost:${PORT}"
exec kubectl -n "${NS}" port-forward "svc/${SERVICE}" "${PORT}:${PORT}"