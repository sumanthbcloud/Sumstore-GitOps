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
