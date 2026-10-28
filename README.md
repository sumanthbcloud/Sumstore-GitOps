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

## Controller & Add-on Version Strategy (Deferred to Live Bootstrap)

To prevent brittle drift and dependency mismatches across environments, controller versions are **not hardcoded** in offline repository assets or documentation:
- **Argo CD (`ARGOCD_VERSION`)**: Must be selected and explicitly pinned immediately before cluster bootstrap based on the Kubernetes 1.30 compatibility matrix and currently supported stable releases.
- **External Secrets Operator (`ESO_VERSION`)**: Must be selected and explicitly pinned immediately before bootstrap based on compatibility with Kubernetes 1.30 and native generator support (`generators.external-secrets.io/v1alpha1`).
- **AWS Load Balancer Controller (`LBC_VERSION`)**: Must be selected and explicitly pinned immediately before bootstrap matching EKS 1.30 and AWS IAM controller policy specifications.

No speculative version upgrades are committed offline. Actual controller versions will be evaluated, selected, and pinned when live cluster bootstrap commences.

---

## Private ECR OCI Helm Authentication Architecture

To enable Argo CD to pull the centralized `microservice:1.0.0` Helm chart from private Amazon ECR (`961544628309.dkr.ecr.us-east-1.amazonaws.com/sumstore/charts`), the platform implements automated, continuous credential rotation via External Secrets Operator:

```
AWS ECR (us-east-1)
       │
       ▼ (ecr:GetAuthorizationToken via EKS Pod Identity)
External Secrets Operator (Controller in external-secrets namespace)
  ├── ECRAuthorizationToken Generator (ecr-token-generator in argocd namespace)
  └── ExternalSecret (repo-sumstore-charts in argocd namespace)
       │
       ▼ (Reconciles every 6 hours — safely below ECR 12h expiration)
Argo CD Repository Secret (repo-sumstore-charts in argocd namespace)
  ├── Label: argocd.argoproj.io/secret-type: repository
  ├── type: helm
  ├── enableOCI: "true"
  ├── url: 961544628309.dkr.ecr.us-east-1.amazonaws.com/sumstore/charts
  ├── username: AWS
  └── password: <temporary ECR token>
       │
       ▼
Argo CD ApplicationSet (sumstore-workloads)
  └── Authenticated OCI pull: oci://961544628309.dkr.ecr.us-east-1.amazonaws.com/sumstore/charts/microservice:1.0.0
```

**Security & Operational Guarantees:**
- **No static ECR passwords or temporary tokens committed to Git.**
- **No static AWS access keys:** Uses EKS Pod Identity with the ESO IAM role (`ecr:GetAuthorizationToken`).
- **No recurring CronJobs:** Uses ESO native `ECRAuthorizationToken` generator (`generators.external-secrets.io/v1alpha1`).
- **Rotation:** `refreshInterval: 6h` guarantees tokens are refreshed well before ECR temporary tokens expire (12 hours).

---

## Day-0 Bootstrap & Deployment Sequence

Platform bootstrapping follows a strict separation between **Bootstrap-Managed Initial Installations** (executed once via CLI/Helm from the administrative workstation) and **Argo-Managed Lifecycles** (reconciled autonomously via GitOps):

```
================================================================================
                    BOOTSTRAP-MANAGED (Client Workstation)
================================================================================
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
Step 3: Initial Controller Installations (Client EC2 / Helm)
   │    • Verify supported stable releases and pin ESO_VERSION and LBC_VERSION
   │    • External Secrets Operator:
   │      helm install external-secrets external-secrets/external-secrets \
   │        -n external-secrets --create-namespace --version "${ESO_VERSION}"
   │    • AWS Load Balancer Controller:
   │      helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
   │        -n kube-system --version "${LBC_VERSION}"
   ▼
Step 4: Initial Argo CD Installation (Client EC2)
   │    • Verify supported stable release and pin ARGOCD_VERSION
   │    • kubectl create namespace argocd
   │    • kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml
   │    • kubectl apply -f argocd/project.yaml
   │    • Configure Git repository credential Secret for Sumstore-GitOps:
   │      kubectl create secret generic repo-sumstore-gitops -n argocd \
   │        --from-literal=type=git \
   │        --from-literal=url=https://github.com/sumanthbcloud/Sumstore-GitOps.git \
   │        --from-literal=username=git \
   │        --from-literal=password="<GITHUB_TOKEN>"
   │      kubectl label secret repo-sumstore-gitops -n argocd argocd.argoproj.io/secret-type=repository
   ▼
Step 5: Populate AWS Secrets Manager Out-of-Band (Client EC2)
   │    • Execute: platform/security/external-secrets/scripts/bootstrap-secrets.sh
   │    • Populates sumstore/mysql and sumstore/rabbitmq in AWS Secrets Manager

================================================================================
                       ARGO-MANAGED (GitOps Autonomous)
================================================================================
Step 6: Platform Security Reconciliation
   │    • kubectl apply -f argocd/platform-security.yaml
   │    • ClusterSecretStore connects via EKS Pod Identity
   │    • ECRAuthorizationToken generator requests temporary ECR credentials
   │    • ESO continuously refreshes Argo CD OCI repository Secret (repo-sumstore-charts) in argocd namespace (refreshInterval: 6h)
   │    • ExternalSecrets synchronize into native Secrets in sumstore namespace:
   │      mysql-secret, shipping-db-secret, ratings-db-secret,
   │      rabbitmq-secret, payment-rabbitmq-secret, dispatch-rabbitmq-secret
   ▼
Step 7: Platform Storage & Datastores Reconciliation
   │    • kubectl apply -f argocd/platform-data.yaml
   │    • StorageClass gp3 initialized (WaitForFirstConsumer)
   │    • MySQL, RabbitMQ, MongoDB, Redis StatefulSets mount Secrets and PVCs
   ▼
Step 8: Platform Networking & Microservices
   │    • kubectl apply -f argocd/platform-networking.yaml (ALB Ingress)
   │    • kubectl apply -f applicationsets/workloads.yaml (8 microservices)
   │    • Argo CD pulls microservice:1.0.0 OCI chart via ESO-refreshed repository credentials
   │    • Argo CD continuously reconciles desired state
```
