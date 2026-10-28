# SUM Store External Secrets Architecture

This directory defines the **External Secrets Operator (ESO)** integration for the SUM Store platform. It bridges credentials stored in **AWS Secrets Manager** to native **Kubernetes Secrets** consumed by datastores and microservices.

---

## 1. Architecture Overview

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

---

## 2. Secret Dependency & Mapping Matrix

| Consumer Workload | Kubernetes Secret Name | Required Secret Keys | Authoritative AWS Secret | AWS Secret Property | Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **MySQL StatefulSet** | `mysql-secret` | `MYSQL_ROOT_PASSWORD`<br>`MYSQL_DATABASE`<br>`SHIPPING_DB_USER`<br>`SHIPPING_DB_PASSWORD`<br>`RATINGS_DB_USER`<br>`RATINGS_DB_PASSWORD` | `sumstore/mysql` | `MYSQL_ROOT_PASSWORD`<br>`MYSQL_DATABASE`<br>`SHIPPING_DB_USER`<br>`SHIPPING_DB_PASSWORD`<br>`RATINGS_DB_USER`<br>`RATINGS_DB_PASSWORD` | Root admin password, primary database initialization (`cities`), and application user provisioning via `30-create-app-users.sh`. |
| **Shipping Service** | `shipping-db-secret` | `DB_USER`<br>`DB_PASSWORD` | `sumstore/mysql` | `SHIPPING_DB_USER`<br>`SHIPPING_DB_PASSWORD` | Java Spring Boot JPA connection credentials to MySQL `cities` database. |
| **Ratings Service** | `ratings-db-secret` | `PDO_USER`<br>`PDO_PASSWORD` | `sumstore/mysql` | `RATINGS_DB_USER`<br>`RATINGS_DB_PASSWORD` | PHP Symfony PDO connection credentials to MySQL `ratings` database. |
| **RabbitMQ StatefulSet** | `rabbitmq-secret` | `RABBITMQ_DEFAULT_USER`<br>`RABBITMQ_DEFAULT_PASS` | `sumstore/rabbitmq` | `RABBITMQ_DEFAULT_USER`<br>`RABBITMQ_DEFAULT_PASS` | Default broker administrator credentials configured on container initialization. |
| **Payment Service** | `payment-rabbitmq-secret` | `AMQP_USER`<br>`AMQP_PASS` | `sumstore/rabbitmq` | `RABBITMQ_DEFAULT_USER`<br>`RABBITMQ_DEFAULT_PASS` | Python Pika AMQP publisher credentials for order queue. |
| **Dispatch Service** | `dispatch-rabbitmq-secret` | `AMQP_USER`<br>`AMQP_PASS` | `sumstore/rabbitmq` | `RABBITMQ_DEFAULT_USER`<br>`RABBITMQ_DEFAULT_PASS` | Go AMQP consumer credentials for order fulfillment processing. |

---

## 3. Directory Structure

```
platform/security/external-secrets/
├── README.md                          # Architecture and operational documentation
├── cluster-secret-store.yaml          # ClusterSecretStore definition for AWS Secrets Manager
├── scripts/
│   └── bootstrap-secrets.sh           # Safe offline/post-EKS credential population script
└── externalsecrets/
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
  3. **Zero In-Cluster Secrets**: The `ClusterSecretStore` manifest requires no static AWS credentials or hardcoded IAM role ARNs. The ESO controller pod automatically discovers credentials via the standard AWS SDK container credential provider (`AWS_CONTAINER_CREDENTIALS_FULL_URI`).

---

## 5. Ownership Boundaries

| Component | Responsibility / Ownership | What it Contains / Manages |
| :--- | :--- | :--- |
| **Shop-Infrastructure** | Terraform | AWS Secrets Manager secret containers (`sumstore/mysql`, `sumstore/rabbitmq`), IAM Role, least-privilege IAM Policy (`GetSecretValue`, `DescribeSecret`), and `aws_eks_pod_identity_association`. **No secret values.** |
| **AWS Secrets Manager** | AWS Cloud (Out-of-band) | Actual encrypted runtime secret strings and credentials. Populated via controlled CLI / bootstrap script. |
| **Sumstore-GitOps** | GitOps / Argo CD | `ClusterSecretStore` and `ExternalSecret` custom resource definitions. Refresh policies and property mapping contracts. **No secret values.** |
| **External Secrets Operator** | In-Cluster Controller | Continuously reconciles `ExternalSecret` definitions against AWS Secrets Manager and writes native `Secret` resources in the `sumstore` namespace. |
| **Kubernetes Secrets** | Cluster Runtime | Native ephemeral `Secret` objects created and managed by ESO (`Owner` creation policy). |
| **Application Workloads** | Helm / Central Platform Chart | Ingests native Secrets transparently via `existingSecret: <name>` without any knowledge of ESO or AWS. |
| **Client EC2 Workstation** | Administrative | Out-of-band operational workstation used to run bootstrap scripts; **not** managed by Terraform. |

---

## 6. Datastore and Application Startup Ordering

To prevent startup failures and crash loops, resources must be created in this strict order:

```
Step 1: EKS Cluster & EKS Pod Identity Agent created (Terraform)
   │
Step 2: External Secrets Operator installed in cluster (Helm / Argo CD)
   │
Step 3: Secrets Manager secret values populated out-of-band (bootstrap-secrets.sh)
   │
Step 4: ClusterSecretStore & ExternalSecrets applied (GitOps)
   │
Step 5: Kubernetes Secrets synchronized by ESO (Status: Ready / SecretSynced)
   │
Step 6: Datastores deployed (MySQL & RabbitMQ StatefulSets mount secrets and initialize)
   │
Step 7: Application workloads deployed (Shipping, Ratings, Payment, Dispatch mount secrets)
```

### Avoiding Circular Dependencies in Argo CD
If Argo CD attempts to synchronize application workloads or datastores before ESO has synchronized secrets, Pods will fail to start because referenced Secrets (`existingSecret`) do not exist. To resolve this:
* Deploy the **Platform Security layer** (`ClusterSecretStore` + `ExternalSecrets`) ahead of datastore and application layers.
* Verify that native Secrets exist in the `sumstore` namespace (`kubectl get secrets -n sumstore`) before launching MySQL, RabbitMQ, and microservice Deployments.

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
