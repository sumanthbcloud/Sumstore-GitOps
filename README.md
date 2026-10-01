# Sumstore-GitOps — Kubernetes & ArgoCD Continuous Delivery

This repository is the single source of truth for all Kubernetes resources, Helm charts, and continuous delivery configurations powering **SUM Store** on Amazon EKS. 

Using **ArgoCD** and declarative GitOps workflows, any commit merged to this repository automatically reconciles live cluster state with desired state—giving us auditable, zero-downtime, and drift-free releases.

---

## What Lives Here

- **ArgoCD Applications (`argocd/`)**: Declarative Application and ApplicationSet definitions watching this repository for automated sync, auto-prune, and self-healing.
- **Helm Charts (`helm/`)**: Packaged microservices definitions with parameterized `values.yaml` files for each component (`catalogue`, `cart`, `shipping`, `payment`, `user`, `ratings`, `dispatch`, `web`).
- **Cluster Infrastructure & Add-ons (`infrastructure/`)**: Cluster-wide components including AWS Load Balancer Controller, metrics-server, Ingress rules, and storage classes.

---

## How Our GitOps Pipeline Works

```
  +--------------------+        +---------------------+
  |   Developer Git    | ---->  |   Sumstore-GitOps   |
  |  Commit & Review   |        |   (This Repository) |
  +--------------------+        +----------+----------+
                                           |
                                      Watches repo
                                           |
                                           v
                               +-----------------------+
                               |     ArgoCD Engine     |
                               | (Reconciliation Loop) |
                               +-----------+-----------+
                                           |
                             Applies manifests & detects drift
                                           |
                                           v
                               +-----------------------+
                               |    Amazon EKS Cluster |
                               |   (Workloads & Pods)  |
                               +-----------------------+
```

1. **Code Merge**: A code change or image tag update is committed to this repository.
2. **Reconciliation**: ArgoCD's controller picks up the Git webhook or poll event and detects differences between Git and the live cluster state.
3. **Automated Sync**: ArgoCD applies the changes, rolls out updated pods, and validates health checks. If an ad-hoc change is made directly in the cluster, ArgoCD automatically self-heals back to the Git definition.

---

## Repository Structure

```
├── argocd/                   # ArgoCD root Application & app manifests
│   ├── root-application.yaml # App-of-apps pattern orchestrating all services
│   └── apps/                 # Individual microservice ArgoCD application specs
├── helm/                     # Helm chart definitions
│   └── sumstore/             # Core multi-service chart
│       ├── Chart.yaml        # Chart metadata and versioning
│       ├── values.yaml       # Default service configurations, replicas, resources
│       └── templates/        # Deployments, Services, ConfigMaps, and Secrets
└── infrastructure/           # Essential cluster add-ons and networking
    ├── alb-ingress.yaml      # AWS ALB Ingress configurations
    └── aws-load-balancer/    # AWS LBC service account & Helm values
```

---

## Deploying & Syncing with ArgoCD

### 1. Prerequisites
- Access to the target Amazon EKS cluster (provisioned via [Shop-Infrastructure](https://github.com/sumanthbcloud/Shop-Infrastructure))
- `kubectl` and `helm` installed locally
- ArgoCD running on the cluster (under the `argocd` namespace)

### 2. Connect to ArgoCD
Forward the ArgoCD UI locally:
```shell
kubectl port-forward svc/argocd-server -n argocd 8080:443
```
Login via CLI or browser (`https://localhost:8080`) using the admin credentials:
```shell
argocd admin initial-password -n argocd
```

### 3. Bootstrap Application Delivery
Deploy the root application (App-of-Apps) to initiate syncing:

```shell
kubectl apply -f argocd/root-application.yaml
```

ArgoCD will discover all child applications and begin reconciling them against the cluster.

### 4. Monitor Sync Status
Check the status of deployed components:
```shell
argocd app list
```

Or sync an individual service manually:
```shell
argocd app sync sumstore-catalogue
```

---

## Managing Updates & Rollouts

- **Updating Container Images**: To deploy a new version of any microservice, update the corresponding `image.tag` inside `helm/sumstore/values.yaml` and push to main. ArgoCD handles the rolling deployment.
- **Scaling Services**: Adjust `replicaCount` or horizontal pod autoscaler thresholds in `values.yaml`.
- **Environment Ingress**: Route rules and TLS termination points are configured declaratively in `infrastructure/alb-ingress.yaml`.

---

## Related Repositories

- **[E-commerce-B2C](https://github.com/sumanthbcloud/E-commerce-B2C)** — Application source code, microservice implementations, container builds, and local development.
- **[Shop-Infrastructure](https://github.com/sumanthbcloud/Shop-Infrastructure)** — Terraform code provisioning the VPC, EKS cluster, node groups, and AWS IAM roles.
