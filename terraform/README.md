# Terraform Automation for Kubernetes Deployments

This Terraform configuration automates the deployment of your Kubernetes services to a local kind cluster.

## Prerequisites

1. **Terraform** (>= 1.0) - [Installation Guide](https://learn.hashicorp.com/tutorials/terraform/install-cli)
2. **kind** - [Installation Guide](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
3. **kubectl** - [Installation Guide](https://kubernetes.io/docs/tasks/tools/)
4. **helm** - [Installation Guide](https://helm.sh/docs/intro/install/)

## Quick Start

### Option 1: Using Helper Scripts (Recommended)

1. **Deploy everything:**
   ```bash
   cd terraform
   ./scripts/deploy.sh
   ```

2. **Destroy everything:**
   ```bash
   cd terraform
   ./scripts/destroy.sh
   ```

### Option 2: Manual Terraform Commands

1. **Initialize Terraform:**
   ```bash
   cd terraform
   terraform init
   ```

2. **Review and customize variables (optional):**
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your preferences
   ```

3. **Plan the deployment:**
   ```bash
   terraform plan
   ```

4. **Apply the configuration:**
   ```bash
   terraform apply
   ```

5. **Access ArgoCD:**
   ```bash
   # Get the admin password
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
   
   # Port-forward ArgoCD server
   kubectl port-forward svc/argocd-server -n argocd 8080:80
   
   # Access ArgoCD UI at http://localhost:8080
   # Username: admin
   # Password: (from command above)
   ```

## What This Terraform Configuration Does

1. **Creates a kind cluster** using your `kind-config.yaml`
2. **Installs ArgoCD** via Helm chart
3. **Creates required namespaces** (argocd, develop, monitoring)
4. **Applies ClusterRoleBinding** for ArgoCD permissions
5. **Deploys all ArgoCD Applications** from the `argo-apps/` directory:
   - Kafka
   - Postgres
   - Zookeeper
   - Schema Registry
   - Mage AI (Helm and No-Helm versions)
   - Grafana
   - Prometheus
6. **Optionally installs NGINX Ingress Controller**

## Configuration

### Variables

Key variables you can customize in `terraform.tfvars`:

- `cluster_name`: Name of the kind cluster (default: "development")
- `kind_config_path`: Path to kind configuration file
- `argocd_version`: ArgoCD Helm chart version
- `install_ingress_controller`: Whether to install NGINX ingress (default: true)
- `git_repo_url`: Git repository URL for ArgoCD applications
- `wait_for_argo`: Wait for ArgoCD to be ready before deploying apps

### Outputs

After applying, Terraform will output:
- Cluster name and kubectl context
- Commands to access ArgoCD
- ArgoCD server URL

## Destroying Resources

To tear down everything:

```bash
terraform destroy
```

This will:
- Delete all ArgoCD applications
- Uninstall ArgoCD
- Delete the kind cluster

## Troubleshooting

### Cluster Already Exists

If the kind cluster already exists, Terraform will skip creation. To recreate:
```bash
kind delete cluster --name development
terraform apply
```

### ArgoCD Not Ready

If ArgoCD takes longer than expected, increase `argo_wait_timeout` in `terraform.tfvars`.

### Check Cluster Status

```bash
kubectl get nodes --context kind-development
kubectl get pods -n argocd --context kind-development
```

### View ArgoCD Applications

```bash
kubectl get applications -n argocd --context kind-development
```

## Workflow

1. **Initial Setup**: Run `terraform apply` to create the cluster and install ArgoCD
2. **Application Updates**: ArgoCD will automatically sync applications from your Git repository
3. **Infrastructure Changes**: Modify Terraform files and run `terraform apply` again
4. **Cleanup**: Run `terraform destroy` when done

## Integration with CI/CD

You can integrate this into your CI/CD pipeline:

```yaml
# Example GitHub Actions workflow
- name: Setup Kubernetes
  run: |
    cd terraform
    terraform init
    terraform apply -auto-approve
```

## Notes

- The kind cluster configuration is read from `../kind-config.yaml`
- ArgoCD applications are deployed from YAML files in `../argo-apps/`
- All applications use automated sync with self-healing enabled
- The configuration assumes your Git repository is publicly accessible or you have proper credentials configured

