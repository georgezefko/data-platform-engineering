#!/usr/bin/env bash
set -euo pipefail
ENV="${1:-dev}"
case "$ENV" in
  # Different hosts on purpose: browsers share cookies across ports, so dev and prod logins
  # on the same host overwrite each other (each env signs tokens with its own key).
  dev)  NS=develop PORT=8081 HOST=127.0.0.1 ;;
  prod) NS=prod    PORT=8082 HOST=localhost ;;
  *) echo "usage: $0 [dev|prod]" >&2; exit 1 ;;
esac
echo "Airflow $ENV UI → http://${HOST}:${PORT}  (admin / admin)"
exec kubectl -n "$NS" port-forward svc/airflow-api-server "${PORT}:8080"
