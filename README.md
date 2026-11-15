# data-platform-engineering

A reproducible, production-inspired local data platform built with Kubernetes, Terraform, Argo CD, and DevContainers.

This repository demonstrates how data engineers can move beyond pipelines and start thinking in terms of platforms—using real-world architectural patterns, entirely on a local machine.

## What's in This Repo

### Platform Stack

All services are deployed and managed by Argo CD from this repository.

| Service | Deployment | Purpose |
|---|---|---|
| Argo CD | bootstrap | GitOps controller — syncs all services from `argo/apps/` |
| PostgreSQL | Kustomize | Source database with logical replication enabled for CDC |
| Kafka + Zookeeper | Kustomize | Message broker for CDC change events |
| Kafka Connect | Kustomize | Hosts the Debezium PostgreSQL connector |
| Schema Registry | Kustomize | Avro schema management for Kafka topics |
| Mage AI | Helm | Data pipeline orchestration |
| Airbyte | Helm | EL(T) connector platform |
| StarRocks | Helm | Real-time analytical database (CDC sink) |

### Architecture

The platform boots in a strict layered order:

```
KinD cluster → Terraform (installs Argo CD) → app-of-apps.yaml → individual Applications → develop namespace
```

Argo CD tracks the `main` branch with `prune: true` and `selfHeal: true`. Pushing to `main` triggers an automated sync.

## Quick Start

If you just want to run the platform without reading the tutorials, follow these steps.

### Prerequisites

- Docker
- VS Code
- VS Code DevContainers extension

### Run the platform

1. Clone the repository:

```bash
git clone https://github.com/georgezefko/data-platform-engineering.git
cd data-platform-engineering
```

2. Open the repository in a DevContainer.

Before opening the DevContainer, create the kubeconfig mount directory if it doesn't exist:

```bash
mkdir -p .kube
```

3. From inside the DevContainer, bootstrap the entire platform:

```bash
make up
```

This command will:
- Create a local Kubernetes cluster using KinD
- Install Argo CD using Terraform
- Deploy all applications using GitOps

After a few minutes, the platform will be ready. Check status with:

```bash
make status
```

### Accessing Platform Components

Because the platform runs inside a DevContainer using Docker-in-Docker, services are accessed via port forwarding. The Makefile includes helpers for the most common components. Run each in a separate terminal.

| Component | Command | Endpoint |
|---|---|---|
| Argo CD UI | `make argo-ui` | http://localhost:8080 (prints admin password) |
| Mage AI | `make mage-ui` | http://localhost:6789 |
| PostgreSQL | `make postgres-pf` | localhost:5432 |
| Kafka Connect | `make kafka-connect-pf` | http://localhost:8083 |
| StarRocks | `make starrocks-pf` | MySQL: localhost:9030 / HTTP: localhost:8030 |

Kafka itself is inspected by running a temporary debug pod inside the cluster — the tutorials cover this.

### Other Useful Make Targets

| Target | Purpose |
|---|---|
| `make status` | Show Argo Application sync status and key namespaces |
| `make tf-apply` | Re-run Terraform (re-installs/upgrades Argo CD) |
| `make argo-bootstrap` | Re-apply the app-of-apps manifest |
| `make kind-down` | Delete the KinD cluster (keeps Terraform state) |
| `make reset` | Full tear-down: cluster + Terraform state + kubeconfig |

## Repository Structure

```
.
├── .devcontainer/             # Reproducible development environment (Docker-in-Docker)
├── infra/
│   ├── kind/                  # KinD single-node cluster config
│   └── terraform/             # Installs Argo CD via Helm (local state)
├── argo/
│   ├── app-of-apps.yaml       # Root Argo Application — applied once by hand
│   └── apps/                  # One Argo Application manifest per service
├── apps/
│   ├── postgres/              # Kustomize — source DB (logical replication enabled)
│   ├── kafka/                 # Kustomize — message broker
│   ├── zookeeper/             # Kustomize — Kafka coordination
│   ├── kafka-connect/         # Kustomize — Debezium CDC connector host
│   ├── kafka-schema-registry/ # Kustomize — Avro schema management
│   ├── mage-ai-helm/          # Helm — data pipeline orchestration
│   ├── airbyte-helm/          # Helm — ELT connectors
│   └── starrocks-helm/        # Helm — real-time analytical database
├── scripts/                   # Bootstrap and port-forward helper scripts
├── tutorials/                 # Step-by-step guides (see below)
└── Makefile                   # Developer workflows
```

The structure reflects execution order and responsibility boundaries:
- cluster creation (`infra/kind/`)
- platform bootstrap (`infra/terraform/`)
- application deployment (`argo/` + `apps/`)

### Deployment patterns

- **Kustomize** services follow a `base/` + `dev/` overlay structure. The Argo Application points at `apps/<service>/dev`.
- **Helm** services use Argo CD multi-source: the chart is pulled from the upstream Helm repo; values come from `apps/<service>/dev/values.yaml` in this repo.

## Tutorials

### 1. From Zero to GitOps: Deploying Mage AI on Local Kubernetes with Argo CD

In the first tutorial, I provide a step by step guide to deploy a local Kubernetes cluster using KinD along with Argo CD for deployment orchestration of your apps. I demonstrate how to deploy Mage AI for data pipeline development using Helm and Kustomize approaches.

You can find relevant article with detailed guide here: [Medium Blog](https://medium.com/gitconnected/from-zero-to-gitops-deploying-mage-ai-on-local-kubernetes-with-argo-cd-25865a035571)

You can find the relevant code here: [turorial_one](https://github.com/georgezefko/data-platform-engineering/tree/tutorial_one)

### 2. Building a Local Data Platform with Kubernetes and Terraform

This tutorial continues from the first one and provides a more automated way to deploy K8s locally. I provide a step by step guide to deploy a local Kubernetes cluster using KinD and Terraform along with Argo CD for deployment orchestration of your apps. I demonstrate how to deploy Mage AI, Kafka and Postgres for end-to-end data pipeline development using Helm and Kustomize approaches.

You can find relevant article with detailed guide here: [tutorial_two](https://medium.com/data-engineer-things/building-a-local-data-platform-with-kubernetes-and-terraform-9547a4256a7f)

### 3. Building a CDC Pipeline with Debezium and Kafka Connect on Local Kubernetes

This tutorial extends the platform by adding Change Data Capture (CDC). It covers deploying Kafka Connect with the Debezium PostgreSQL connector, wiring the connector registration as a GitOps PostSync hook, and consuming live change events from the mage database. It also covers adding StarRocks as a CDC sink and wiring the stream into an append-only event log for downstream analytics.

You can find the relevant article with detailed guide here: [Medium Blog](https://medium.com/data-engineer-things/building-a-cdc-pipeline-with-debezium-and-kafka-connect-on-local-kubernetes-d75fd5761d72)

You can find the relevant code here: [feat/debezium](https://github.com/georgezefko/data-platform-engineering/tree/feat/debezium)

Step-by-step references:
- [Debezium + Kafka Connect setup](tutorials/03-debezium-cdc-pipeline.md)
- [Adding StarRocks as a CDC sink](tutorials/04-starrocks-cdc-sink.md)
- [StarRocks Routine Load — CDC event log](tutorials/05-starrocks-routine-load.md)

### 4. Deploying Airflow (WIP)

Airflow 3 in two environments (dev and prod) from the official Helm chart, with DAGs pulled at runtime from the `airflow-monorepo` repo as Git bundles.

- [Deploying Airflow on the local platform](tutorials/06-airflow-deployment.md)
