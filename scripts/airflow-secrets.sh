#!/usr/bin/env bash
# Secrets Airflow needs on kind, in both Airflow namespaces. Never committed; Argo doesn't manage
# them, so prune leaves them alone.
#   airflow-gcp-adc: your ADC file for BigQuery. Run `gcloud auth application-default login` first.
#   airflow-keys:    fernet/API/JWT keys. Created once, never rotated by a re-run (a new fernet key
#                    would make stored connections unreadable).
#   analytics-postgres: where the pg-load app writes. Both envs use the platform Postgres in
#                    `develop`, each with its own database (pg-load creates it on the first load).
set -euo pipefail
# 32 random bytes, url-safe base64: the fernet key format (also fine for the API/JWT keys)
key() { head -c 32 /dev/urandom | base64 | tr '+/' '-_'; }
# Prod lives in its own GCP project: PROD_ADC lets it use different credentials (defaults to ADC).
ADC="${ADC:-$HOME/.config/gcloud/application_default_credentials.json}"
PROD_ADC="${PROD_ADC:-$ADC}"

for ns in develop prod; do
  adc=$ADC; [[ $ns == prod ]] && adc=$PROD_ADC
  db=analytics_dev; [[ $ns == prod ]] && db=analytics_prod
  [[ -f "$adc" ]] || { echo "No ADC file at $adc. Run: gcloud auth application-default login" >&2; exit 1; }
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "$ns" create secret generic airflow-gcp-adc --from-file=adc.json="$adc" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "$ns" create secret generic analytics-postgres \
    --from-literal=PGHOST=postgres.develop.svc.cluster.local --from-literal=PGPORT=5432 \
    --from-literal=PGUSER=postgres --from-literal=PGPASSWORD=postgres --from-literal=PGDATABASE="$db" \
    --dry-run=client -o yaml | kubectl apply -f -

  if ! kubectl -n "$ns" get secret airflow-keys >/dev/null 2>&1; then
    kubectl -n "$ns" create secret generic airflow-keys \
      --from-literal=fernet-key="$(key)" \
      --from-literal=api-secret-key="$(key)" \
      --from-literal=jwt-secret="$(key)"
  fi
done
