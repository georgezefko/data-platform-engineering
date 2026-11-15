#!/usr/bin/env bash
# Secrets Airflow needs on kind, in both Airflow namespaces. Never committed; Argo doesn't manage
# them, so prune leaves them alone.
#   airflow-gcp-adc: your ADC file for BigQuery. Run `gcloud auth application-default login` first.
#   airflow-keys:    fernet/API/JWT keys. Created once, never rotated by a re-run (a new fernet key
#                    would make stored connections unreadable).
set -euo pipefail
# 32 random bytes, url-safe base64: the fernet key format (also fine for the API/JWT keys)
key() { head -c 32 /dev/urandom | base64 | tr '+/' '-_'; }
ADC="${ADC:-$HOME/.config/gcloud/application_default_credentials.json}"
[[ -f "$ADC" ]] || { echo "No ADC file at $ADC. Run: gcloud auth application-default login" >&2; exit 1; }

for ns in develop prod; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "$ns" create secret generic airflow-gcp-adc --from-file=adc.json="$ADC" \
    --dry-run=client -o yaml | kubectl apply -f -

  if ! kubectl -n "$ns" get secret airflow-keys >/dev/null 2>&1; then
    kubectl -n "$ns" create secret generic airflow-keys \
      --from-literal=fernet-key="$(key)" \
      --from-literal=api-secret-key="$(key)" \
      --from-literal=jwt-secret="$(key)"
  fi
done
