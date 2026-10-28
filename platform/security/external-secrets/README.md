# SUM Store External Secrets Architecture

This directory defines the **External Secrets Operator (ESO)** integration for the SUM Store platform. It bridges credentials stored in **AWS Secrets Manager** and **Amazon ECR** to native **Kubernetes Secrets** consumed by datastores, microservices, and Argo CD.

---

## 1. Architecture Overview

The platform uses ESO for two critical credential lifecycles:

### A. Datastore & Application Secrets (AWS Secrets Manager)
```
AWS Secrets Manager (Containers)
  ├── sumstore/mysql
  └── sumstore/rabbitmq
            │
            ▼ (Read via EKS Pod Identity: GetSecretValue, DescribeSecret)
External Secrets Operator (Controller in external-secrets namespace)
  └── ClusterSecretStore (sumstore-secretsmanager)
            │
            ▼ (Reconciles ExternalSecrets every 1h)
Kubernetes Secrets (sumstore namespace)
  ├── mysql-secret             ──► MySQL StatefulSet
  ├── shipping-db-secret       ──► Shipping Deployment
  ├── ratings-db-secret        ──► Ratings Deployment
  ├── rabbitmq-secret          ──► RabbitMQ StatefulSet
  ├── payment-rabbitmq-secret  ──► Payment Deployment
  └── dispatch-rabbitmq-secret ──► Dispatch Deployment
```

### B. Private ECR OCI Helm Repository Authentication
```
Amazon ECR (961544628309.dkr.ecr.us-east-1.amazonaws.com)
            │
            ▼ (ecr:GetAuthorizationToken via EKS Pod Identity)
External Secrets Operator (Controller in external-secrets namespace)
  ├── ECRAuthorizationToken Generator (ecr-token-generator in argocd namespace)
  └── ExternalSecret (repo-sumstore-charts in argocd namespace)
            │
            ▼ (Reconciles every 6h — safely below ECR 12h expiration)
Argo CD Repository Secret (repo-sumstore-charts in argocd namespace)
  ├── Labels: argocd.argoproj.io/secret-type: repository
  ├── type: helm
  ├── enableOCI: "true"
  ├── url: 961544628309.dkr.ecr.us-east-1.amazonaws.com/sumstore/charts
  ├── username: AWS
  └── password: <temporary ECR token>
            │
            ▼
Argo CD ApplicationSet (sumstore-workloads)
  └── Authenticated pull: oci://961544628309.dkr.ecr.us-east-1.amazonaws.com/sumstore/charts/microservice:1.0.0
```

---

## 2. Secret Dependency & Mapping Matrix

### Application & Datastore Secrets (Namespace: `sumstore`)

| Consumer Workload | Kubernetes Secret Name | Required Secret Keys | Authoritative AWS Secret | AWS Secret Property | Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **MySQL StatefulSet** | `mysql-secret` | `MYSQL_ROOT_PASSWORD`<br>`MYSQL_DATABASE`<br>`SHIPPING_DB_USER`<br>`SHIPPING_DB_PASSWORD`<br>`RATINGS_DB_USER`<br>`RATINGS_DB_PASSWORD` | `sumstore/mysql` | `MYSQL_ROOT_PASSWORD`<br>`MYSQL_DATABASE`<br>`SHIPPING_DB_USER`<br>`SHIPPING_DB_PASSWORD`<br>`RATINGS_DB_USER`<br>`RATINGS_DB_PASSWORD` | Root admin password, primary database initialization (`cities`), and application user provisioning via `30-create-app-users.sh`. |
| **Shipping Service** | `shipping-db-secret` | `DB_USER`<br>`DB_PASSWORD` | `sumstore/mysql` | `SHIPPING_DB_USER`<br>`SHIPPING_DB_PASSWORD` | Java Spring Boot JPA connection credentials to MySQL `cities` database. |
| **Ratings Service** | `ratings-db-secret` | `PDO_USER`<br>`PDO_PASSWORD` | `sumstore/mysql` | `RATINGS_DB_USER`<br>`RATINGS_DB_PASSWORD` | PHP Symfony PDO connection credentials to MySQL `ratings` database. |
| **RabbitMQ StatefulSet** | `rabbitmq-secret` | `RABBITMQ_DEFAULT_USER`<br>`RABBITMQ_DEFAULT_PASS` | `sumstore/rabbitmq` | `RABBITMQ_DEFAULT_USER`<br>`RABBITMQ_DEFAULT_PASS` | Default broker administrator credentials configured on container initialization. |
| **Payment Service** | `payment-rabbitmq-secret` | `AMQP_USER`<br>`AMQP_PASS` | `sumstore/rabbitmq` | `RABBITMQ_DEFAULT_USER`<br>`RABBITMQ_DEFAULT_PASS` | Python Pika AMQP publisher credentials for order queue. |
| **Dispatch Service** | `dispatch-rabbitmq-secret` | `AMQP_USER`<br>`AMQP_PASS` | `sumstore/rabbitmq` | `RABBITMQ_DEFAULT_USER`<br>`RABBITMQ_DEFAULT_PASS` | Go AMQP consumer credentials for order fulfillment processing. |

### ECR OCI Repository Secret (Namespace: `argocd`)

| Consumer Workload | Kubernetes Secret Name | Required Secret Keys / Properties | Authoritative Generator | Generator Property | Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Argo CD Server & Repo Server** | `repo-sumstore-charts` | `type: helm`<br>`name: sumstore-charts`<br>`enableOCI: "true"`<br>`url: 961544628309.dkr.ecr.us-east-1.amazonaws.com/sumstore/charts`<br>`username: AWS`<br>`password: <token>` | `ECRAuthorizationToken` (`ecr-token-generator`) | `.username`<br>`.password` | Authenticates Argo CD repo server to pull private OCI Helm chart `microservice:1.0.0` from Amazon ECR. Rotated every 6 hours. |

---

## 3. Directory Structure

```
platform/security/external-secrets/
├── README.md                          # Architecture and operational documentation
├── cluster-secret-store.yaml          # ClusterSecretStore definition for AWS Secrets Manager
├── ecr-token-generator.yaml           # ECRAuthorizationToken generator for Amazon ECR
├── scripts/
│   └── bootstrap-secrets.sh           # Safe offline/post-EKS credential population script
└── externalsecrets/
    ├── argocd-ecr-repo.yaml           # ExternalSecret generating repo-sumstore-charts in argocd namespace
    ├── mysql.yaml                     # ExternalSecret generating mysql-secret
    ├── shipping-db.yaml               # ExternalSecret generating shipping-db-secret
    ├── ratings-db.yaml                # ExternalSecret generating ratings-db-secret
    ├── rabbitmq.yaml                  # ExternalSecret generating rabbitmq-secret
    ├── payment-rabbitmq.yaml          # ExternalSecret generating payment-rabbitmq-secret
    └── dispatch-rabbitmq.yaml         # ExternalSecret generating dispatch-rabbitmq-secret
```

---

## 4. Authentication Architecture: EKS Pod Identity vs. IRSA

* **Decision**: **EKS Pod Identity** is selected as the primary authentication mechanism.
* **Rationale**:
  1. **Architectural Consistency**: `Shop-Infrastructure` already utilizes EKS Pod Identity for the AWS EBS CSI Driver (`eks-pod-identity-agent` addon + `aws_eks_pod_identity_association`).
  2. **No OIDC Provider Overhead**: IRSA requires provisioning and maintaining an IAM OpenID Connect (OIDC) provider per cluster and injecting role ARNs as service account annotations. EKS Pod Identity decouples IAM roles from cluster OIDC issuers.
  3. **Zero In-Cluster Secrets**: The `ClusterSecretStore` and `ECRAuthorizationToken` generator manifests require no static AWS credentials or hardcoded IAM role ARNs. The ESO controller pod automatically discovers credentials via the standard AWS SDK container credential provider (`AWS_CONTAINER_CREDENTIALS_FULL_URI`).
  4. **ECR Token Generation**: The ESO IAM role (`${cluster_name}-external-secrets-role`) includes `ecr:GetAuthorizationToken` on `*`. When the generator executes, ESO calls AWS ECR directly using Pod Identity without static keys or STS assume-role overhead.

---

## 5. Ownership Boundaries

| Component | Responsibility / Ownership | What it Contains / Manages |
| :--- | :--- | :--- |
| **Shop-Infrastructure** | Terraform | AWS Secrets Manager secret containers (`sumstore/mysql`, `sumstore/rabbitmq`), IAM Role, least-privilege IAM Policy (`GetSecretValue`, `DescribeSecret`, `ecr:GetAuthorizationToken`), and `aws_eks_pod_identity_association`. **No secret values.** |
| **AWS Secrets Manager** | AWS Cloud (Out-of-band) | Actual encrypted runtime secret strings and credentials. Populated via controlled CLI / bootstrap script. |
| **Sumstore-GitOps** | GitOps / Argo CD | `ClusterSecretStore`, `ECRAuthorizationToken` generator, and `ExternalSecret` custom resource definitions. Refresh policies and property mapping contracts. **No secret values.** |
| **External Secrets Operator** | In-Cluster Controller | Continuously reconciles `ExternalSecret` definitions against AWS Secrets Manager and Amazon ECR; writes native `Secret` resources in the `sumstore` and `argocd` namespaces. |
| **Kubernetes Secrets** | Cluster Runtime | Native ephemeral `Secret` objects created and managed by ESO (`Owner` creation policy). |
| **Application Workloads** | Helm / Central Platform Chart | Ingests native Secrets transparently via `existingSecret: <name>` without any knowledge of ESO or AWS. |
| **Client EC2 Workstation** | Administrative | Out-of-band operational workstation used to run bootstrap scripts; **not** managed by Terraform. |

---

## 6. Platform Ordering & Dependency Chain

The bootstrap workflow strictly distinguishes between **Bootstrap-Managed** initial controller installations and **Argo-Managed** continuous synchronization to avoid circular dependencies:

### A. Bootstrap-Managed (One-time CLI setup from Client Workstation)
1. **ESO Installed**: External Secrets Operator installed via Helm (`external-secrets` namespace) with Pod Identity active.
2. **AWS LBC Installed**: AWS Load Balancer Controller installed via Helm (`kube-system` namespace).
3. **Argo CD Installed**: Argo CD installed via manifests (`argocd` namespace) with Git repository credentials configured for `Sumstore-GitOps`.
4. **Secrets Populated**: `bootstrap-secrets.sh` executed out-of-band to populate AWS Secrets Manager.

### B. Argo-Managed (GitOps Reconciled)
1. **Platform Security Synchronized**: Argo CD applies `platform/security/external-secrets`.
   - `ClusterSecretStore` connects to AWS Secrets Manager.
   - `ECRAuthorizationToken` generator and `ExternalSecret` synchronize `repo-sumstore-charts` into the `argocd` namespace with label `argocd.argoproj.io/secret-type: repository`.
   - Datastore secrets synchronized into the `sumstore` namespace.
2. **Repository Credentials Active**: Argo CD detects `repo-sumstore-charts`, granting it authenticated read access to `961544628309.dkr.ecr.us-east-1.amazonaws.com/sumstore/charts`.
3. **Datastores Synchronized**: `platform-data` initializes storage classes and stateful databases.
4. **Workloads Deployed**: `applicationsets/workloads.yaml` pulls the `microservice:1.0.0` Helm chart from private ECR OCI and deploys all 8 microservices.

### Expected ECR Authentication Dependency:
```
ESO installed
→ ESO Pod Identity active
→ ECR token generator (ecr-token-generator)
→ ExternalSecret (repo-sumstore-charts)
→ Argo CD repository credential Secret created
→ Argo CD can pull microservice:1.0.0
```

---

## 7. Secret Value Population Procedure (Post-Infrastructure)

Run this procedure **only after** AWS infrastructure has been provisioned:

```bash
# 1. Authenticate with AWS
export AWS_REGION="us-east-1"

# 2. (Optional) Provide explicit credentials, or let the script generate strong random values:
# export MYSQL_ROOT_PASSWORD="MySecureRootPassword123"
# export SHIPPING_DB_PASSWORD="MyShippingPassword123"
# export RATINGS_DB_PASSWORD="MyRatingsPassword123"
# export RABBITMQ_DEFAULT_PASS="MyRabbitMqPassword123"

# 3. Execute the controlled bootstrap script:
./platform/security/external-secrets/scripts/bootstrap-secrets.sh
```
