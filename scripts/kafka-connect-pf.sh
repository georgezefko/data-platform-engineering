#!/usr/bin/env bash
set -euo pipefail

NS="develop"
SERVICE="kafka-connect-svc"
PORT=8083

echo "Kafka Connect REST API → http://localhost:${PORT}"
exec kubectl -n "${NS}" port-forward "svc/${SERVICE}" "${PORT}:${PORT}"
