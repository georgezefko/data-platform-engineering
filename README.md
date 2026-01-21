# data-platform-engineering

A reproducible, production-inspired local data platform built with Kubernetes, Terraform, Argo CD, and DevContainers.

This repository demonstrates how data engineers can move beyond pipelines and start thinking in terms of platforms—using real-world architectural patterns, entirely on a local machine.

## Quick Start

If you just want to run the platform without reading the tutorials, follow these steps.

### Prerequisites	
- Docker
- VS Code
- VS Code DevContainers extension

### Run the platform

1.	Clone the repository:

```console
git clone https://github.com/georgezefko/data-platform-engineering.git
cd data-platform-engineering
```

2. Open the repository in a DevContainer.

To be on the safe side here do this

```python
# TODO: need to add that in a post create command in devcontainer

mkdir .kube
```

3.	From inside the DevContainer, bootstrap the entire platform:

```python
make up
```

This command will:
- create a local Kubernetes cluster using kind
- install Argo CD using Terraform
- deploy all applications using GitOps

After a few minutes, the platform will be ready.

### Accessing Platform Components

Because the platform runs inside a DevContainer using Docker-in-Docker, services are accessed via port forwarding. The Makefile includes helpers for the most common components.

1. Argo CD UI

```python
make argo-ui
```

2. Mage-ai UI

```python
make mage-ui
```

3. PostgreSQL

```python
make postgres-pf
```

Kafka can be inspected by running a temporary debug pod inside the cluster. See the tutorials below for details.

## Repository Structure
```python
.
├── .devcontainer/   # Reproducible development environment
├── scripts/         # Bootstrap and helper scripts
├── infra/           # Infrastructure definitions
│   ├── terraform/   # Platform bootstrap (Argo CD)
│   └── kind/        # Local Kubernetes cluster config
├── apps/            # Application deployment configuration
├── argo/            # Argo CD GitOps manifests
├── Makefile         # Common developer workflows
└── README.md
```

The structure reflects execution order and responsibility boundaries:
	•	cluster creation
	•	platform bootstrap
	•	application deployment

## Tutorials

### 1. From Zero to GitOps: Deploying Mage AI on Local Kubernetes with Argo CD

In the first tutorial, I provide a step by step guide to deploy a local Kubernetes cluster using KinD along with Argo CD for deployment orchestration of your apps. I demonstrate how to deploy Mage AI for data pipeline development using Helm and Kustomize approaches.

You can find relevant article with detailed guide here: [Medium Blog](https://medium.com/gitconnected/from-zero-to-gitops-deploying-mage-ai-on-local-kubernetes-with-argo-cd-25865a035571)

You can find the relevant code here: [turorial_one](https://github.com/georgezefko/data-platform-engineering/tree/tutorial_one)

### 2. Building a Local Data Platform with Kubernetes and Terraform

This tutorial continues from the first one and provides a more automated way to deploy K8s locally.  I provide a step by step guide to deploy a local Kubernetes cluster using KinD and Terraform along with Argo CD for deployment orchestration of your apps. I demonstrate how to deploy Mage AI, Kafka and Postgres for end-to-end data pipeline development using Helm and Kustomize approaches.

You can find relevant article with detailed guide here: TBA


