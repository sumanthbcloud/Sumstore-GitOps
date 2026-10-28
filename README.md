# Sumstore-GitOps — Enterprise GitOps Platform

This repository is the single source of truth for the desired state of all SUM Store microservices and platform infrastructure running on Kubernetes.

Using **Argo CD** and an enterprise service-oriented **ApplicationSet** pattern, workloads consume the centralized platform Helm OCI chart and decouple service deployments into independent sync, health, and rollback boundaries.

---

## Architecture & Ownership Boundaries

The SUM Store engineering ecosystem enforces strict separation of responsibilities across specialized repositories:

1. **Application Source (`E-commerce-B2C`)**:
   - Owns application logic, Dockerfiles, unit tests, and source code.
   - Produces immutable container images tagged with the exact Git commit SHA.
2. **Platform Workflows (`Sumstore-Platform-Workflows`)**:
   - Owns reusable CI Golden Path pipelines (secret scanning, testing, container builds, Trivy vulnerability gating, AWS OIDC, ECR publishing).
   - Updates target image tags in GitOps upon successful CI completion.
3. **Platform Charts (`Sumstore-Platform-Charts`)**:
   - Owns the centralized `microservice` Helm chart, schema validation contracts (`values.schema.json`), and OCI publication to Amazon ECR.
   - Releases immutable semantic versions (`x.y.z`).
4. **GitOps Repository (`Sumstore-GitOps`) [This Repository]**:
   - Owns desired state: service configuration parameters, replica sizing, environment variables, resource allocations, and Argo CD management.
   - Pins the platform chart version and tracks the latest validated image commit SHA.
5. **Infrastructure (`Shop-Infrastructure`)**:
   - Owns AWS foundational resources: VPC, subnets, EKS clusters, node groups, and cloud IAM roles.

---

## Two Independent Version Dimensions

A core architectural principle of this platform is the decoupling of application code from deployment mechanics:

| Dimension | Managed By | Version Format | Lifecycle & Purpose |
|---|---|---|---|
| **Image Version** | Application CI (`E-commerce-B2C`) | **Immutable Git SHA** (`<commit-sha>`) | Updated frequently per service upon code merges. Identifies the exact application binary/container artifact. |
| **Chart Version** | Platform Engineering (`Sumstore-Platform-Charts`) | **Pinned SemVer** (`1.0.0`) | Updated deliberately across services when Kubernetes deployment contracts, schema rules, or platform templates evolve. |

---

## Repository Structure

```
├── applicationsets/
│   └── workloads.yaml             # ApplicationSet generating 8 isolated microservice Applications
├── apps/                          # Per-service values contracts consumed via multiple-sources
│   ├── cart/values.yaml
│   ├── catalogue/values.yaml
│   ├── dispatch/values.yaml
│   ├── payment/values.yaml
│   ├── ratings/values.yaml
│   ├── shipping/values.yaml
│   ├── user/values.yaml
│   └── web/values.yaml
├── argocd/
│   └── project.yaml               # AppProject defining source/destination governance
└── platform/
    ├── networking/
    │   └── ingress/
    │       └── ingress.yaml       # Shared AWS ALB Ingress with routing transforms
    └── data/                      # Stateful backend datastores & storage classes
        ├── mongodb/
        ├── mysql/
        ├── rabbitmq/
        ├── redis/
        └── storageclass.yaml
```

---

## Argo CD ApplicationSet Model

Workloads are deployed via `applicationsets/workloads.yaml` using Argo CD **multiple sources**:
1. **Source 1 (Platform Chart)**:
   - Registry: `961544628309.dkr.ecr.us-east-1.amazonaws.com/sumstore/charts`
   - Chart: `microservice`
   - Target Revision: `1.0.0`
2. **Source 2 (GitOps Values)**:
   - Repo: `https://github.com/sumanthbcloud/Sumstore-GitOps.git`
   - Target Revision: `main`
   - Path: `$values/apps/{{service}}/values.yaml`

This generates 8 independent Argo CD applications (`cart`, `catalogue`, `user`, `shipping`, `payment`, `ratings`, `dispatch`, `web`), each providing isolated deployment failure domains, individual automated sync policies (`selfHeal: true`, `prune: true`), and independent rollbacks.

---

## Day-0 Bootstrap & Deployment Sequence

When an EKS cluster is provisioned, platform components and workloads must be bootstrapped in a strict, deterministic sequence:

```
Step 1: AWS Foundation & EKS Cluster (Shop-Infrastructure)
   │    • VPC, private subnets, NAT Gateway, EKS control plane (private endpoint)
   │    • EKS Pod Identity agent & AWS EBS CSI driver
   │    • EKS Access Entry for administrative client workstation
   │    • IAM roles & Pod Identity associations for ESO and AWS Load Balancer Controller
   ▼
Step 2: Administrative Client EC2 Workstation (AWS CLI)
   │    • Launched into private subnet via scripts/create-eks-client.sh
   │    • Connect via AWS Systems Manager: aws ssm start-session --target <instance-id>
   │    • Configures kubeconfig: aws eks update-kubeconfig --name sum-shop
   │    • Verifies cluster connectivity: kubectl get nodes
   ▼
Step 3: Initial Argo CD Installation (Client EC2)
   │    • kubectl create namespace argocd
   │    • kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.0/manifests/install.yaml
   │    • kubectl apply -f argocd/project.yaml
   ▼
Step 4: Repository Credentials (Client EC2)
   │    • GitHub PAT for private Sumstore-GitOps repository:
   │      kubectl create secret generic repo-sumstore-gitops -n argocd \
   │        --from-literal=type=git \
   │        --from-literal=url=https://github.com/sumanthbcloud/Sumstore-GitOps.git \
   │        --from-literal=username=git \
   │        --from-literal=password="<GITHUB_TOKEN>"
   │      kubectl label secret repo-sumstore-gitops -n argocd argocd.argoproj.io/secret-type=repository
   │    • ECR OCI Helm repository secret for sumstore/charts (refreshed via ESO or cronjob)
   ▼
Step 5: Controllers Installation (Client EC2 / Helm)
   │    • External Secrets Operator (helm install external-secrets external-secrets/external-secrets -n external-secrets)
   │    • AWS Load Balancer Controller (helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system)
   ▼
Step 6: Populate AWS Secrets Manager Out-of-Band (Client EC2)
   │    • Execute: platform/security/external-secrets/scripts/bootstrap-secrets.sh
   │    • Populates sumstore/mysql and sumstore/rabbitmq
   ▼
Step 7: Platform Security Reconciliation
   │    • kubectl apply -f argocd/platform-security.yaml
   │    • ClusterSecretStore connects via EKS Pod Identity
   │    • ExternalSecrets synchronize into native Secrets in sumstore namespace:
   │      mysql-secret, shipping-db-secret, ratings-db-secret,
   │      rabbitmq-secret, payment-rabbitmq-secret, dispatch-rabbitmq-secret
   ▼
Step 8: Platform Storage & Datastores Reconciliation
   │    • kubectl apply -f argocd/platform-data.yaml
   │    • StorageClass gp3 initialized (WaitForFirstConsumer)
   │    • MySQL, RabbitMQ, MongoDB, Redis StatefulSets mount Secrets and PVCs
   ▼
Step 9: Platform Networking & Microservices
   │    • kubectl apply -f argocd/platform-networking.yaml (ALB Ingress)
   │    • kubectl apply -f applicationsets/workloads.yaml (8 microservices)
   │    • Argo CD continuously reconciles desired state
```
