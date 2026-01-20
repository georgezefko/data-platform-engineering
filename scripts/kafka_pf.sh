#!/usr/bin/env bash
set -euo pipefail

NS="develop"
SERVICE="kafka-svc"
PORT=9092

echo "Mage UI → http://localhost:${PORT}"
exec kubectl -n "${NS}" port-forward "svc/${SERVICE}" "${PORT}:${PORT}"