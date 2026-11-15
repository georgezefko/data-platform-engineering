#!/usr/bin/env bash
set -euo pipefail
ENV="${1:-dev}"
case "$ENV" in
  dev)  NS=develop PORT=8081 ;;
  prod) NS=prod    PORT=8082 ;;
  *) echo "usage: $0 [dev|prod]" >&2; exit 1 ;;
esac
echo "Airflow $ENV UI → http://localhost:${PORT}  (admin / admin)"
exec kubectl -n "$NS" port-forward svc/airflow-api-server "${PORT}:8080"
