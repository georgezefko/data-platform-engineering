FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG TERRAFORM_VERSION=1.6.6
ARG KUBECTL_VERSION=1.30.3
ARG HELM_VERSION=3.15.3
ARG KUSTOMIZE_VERSION=5.4.2
ARG KIND_VERSION=0.23.0
ARG YQ_VERSION=4.44.3

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git jq unzip bash-completion make \
    && rm -rf /var/lib/apt/lists/*

# kubectl
RUN curl -fsSL -o /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl

# helm
RUN curl -fsSL -o /tmp/helm.tgz \
    "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
    && tar -xzf /tmp/helm.tgz -C /tmp \
    && mv /tmp/linux-amd64/helm /usr/local/bin/helm \
    && chmod +x /usr/local/bin/helm \
    && rm -rf /tmp/helm.tgz /tmp/linux-amd64

# kustomize
RUN curl -fsSL -o /tmp/kustomize.tgz \
    "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
    && tar -xzf /tmp/kustomize.tgz -C /usr/local/bin \
    && chmod +x /usr/local/bin/kustomize \
    && rm -f /tmp/kustomize.tgz

# kind
RUN curl -fsSL -o /usr/local/bin/kind \
    "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-amd64" \
    && chmod +x /usr/local/bin/kind

# terraform
RUN curl -fsSL -o /tmp/terraform.zip \
    "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
    && unzip /tmp/terraform.zip -d /usr/local/bin \
    && chmod +x /usr/local/bin/terraform \
    && rm -f /tmp/terraform.zip

# yq
RUN curl -fsSL -o /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
    && chmod +x /usr/local/bin/yq

# Nice-to-haves: bash completion
RUN kubectl completion bash > /etc/bash_completion.d/kubectl \
 && helm completion bash > /etc/bash_completion.d/helm \
 && terraform -install-autocomplete || true
