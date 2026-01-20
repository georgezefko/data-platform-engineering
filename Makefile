SHELL := /usr/bin/env bash

CLUSTER_NAME ?= development
TF_DIR := infra/terraform/environments/dev

.PHONY: help up tf-init tf-apply argo-bootstrap argo-ui status reset kind-down

help:
	@echo "Targets:"
	@echo "  make up            - kind up + terraform apply + apply app-of-apps"
	@echo "  make tf-apply      - terraform apply only"
	@echo "  make argo-ui       - port-forward Argo CD UI + print password"
	@echo "  make status        - show Argo Applications + key namespaces"
	@echo "  make reset         - delete cluster + clean terraform state (local) + remove repo kubeconfig"
	@echo "  make kind-down     - delete kind cluster only"

up:
	@bash scripts/bootstrap.sh

tf-init:
	@cd $(TF_DIR) && terraform init

tf-apply:
	@cd $(TF_DIR) && terraform init && terraform apply -auto-approve

argo-bootstrap:
	@kubectl apply -f argo/app-of-apps.yaml

argo-ui:
	@bash scripts/argocd-ui.sh

mage-ui:
	@bash scripts/mage-ui.sh

postgres-pf:
	@bash scripts/postgrespf.sh

kafka-pf:
	@bash scripts/kafka_pf.sh

status:
	@echo "== Argo Applications =="
	@kubectl get applications -n argocd || true
	@echo
	@echo "== Namespaces =="
	@kubectl get ns | egrep 'argocd|dev|develop|ingress-nginx' || true

kind-down:
	@bash scripts/kind-down.sh $(CLUSTER_NAME)

reset:
	@bash scripts/reset.sh $(CLUSTER_NAME)
