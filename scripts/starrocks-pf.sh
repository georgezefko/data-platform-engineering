#!/usr/bin/env bash
set -euo pipefail

NS="develop"
SERVICE="starrocks-fe-service"
MYSQL_PORT=9030
HTTP_PORT=8030

echo "StarRocks FE MySQL → localhost:${MYSQL_PORT}  (mysql -h127.0.0.1 -P${MYSQL_PORT} -uroot)"
echo "StarRocks FE HTTP  → http://localhost:${HTTP_PORT}"
exec kubectl -n "${NS}" port-forward "svc/${SERVICE}" "${MYSQL_PORT}:${MYSQL_PORT}" "${HTTP_PORT}:${HTTP_PORT}"
