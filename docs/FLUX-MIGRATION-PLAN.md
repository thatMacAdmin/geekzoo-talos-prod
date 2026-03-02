# Flux CD Migration Plan – Geekzoo Talos Production

This document is a step-by-step plan to restructure the repository for Flux GitOps and connect the existing flux-operator installation to this repo so the cluster is fully driven by Flux sync. The goal is a **bootstrap-able cluster**: after Omni/Talos bring the cluster up, Flux can sync once and bring the rest of the stack to the correct state without manual ordering.

---

## 1. Bootstrap context: what Omni/Talos own vs what Flux owns

- **Omni / Talos** (outside Flux, managed from this repo but applied by Omni):
  - Cluster provisioning and machine config.
  - Cilium CNI configuration.
  - Anything required to get a running, empty Kubernetes cluster with networking.

- **Flux** (this repo, after cluster is up):
  - Everything from “first storage and secrets” through apps. Flux is the single mechanism to go from “empty cluster” to “fully deployed” in the right order.

So the bootstrap story is: **Omni stands up the cluster → install flux-operator and apply FluxInstance (once) → Flux syncs and applies the rest in dependency order.** No manual `kubectl apply` of application or infrastructure manifests after that.

---

## 2. Current state summary

- **Flux operator**: Installed (e.g. via Helm in `flux-system`).
- **FluxInstance**: Exists at `flux/instance/instance.yaml` but has **no `spec.sync`** – Flux controllers run but do not sync from Git.
- **Manifests**: Applied manually; layout is flat with no `clusters/` or clear infra vs apps split.
- **Traefik**: Kustomize references `helm-rendered.yaml` (file not in repo) – either generated offline or needs to move to Flux HelmRelease.

**Existing layout (simplified):**

```
geekzoo-talos-prod/
├── flux/
│   ├── operator/           # Helm values for flux-operator
│   └── instance/            # FluxInstance (no sync)
├── namespaces/
├── cert-manager/           # ClusterIssuers only
├── traefik/                # Helm chart ref + values + Kustomize (helm-rendered.yaml)
├── media/jellyfin/         # Raw manifests
├── apps/cloudflare/
├── storage/                # Rook, NFS
├── secrets/                # External Secrets (ESO config + ExternalSecret CRs)
└── omni/                   # Talos/Omni – out of scope for Flux
```

---

## 3. Bootstrap order (dependency chain)

To get as close to a **fully bootstrap-able cluster** as possible, Flux must apply resources in this order:

1. **Namespaces** – All core namespaces (including `rook-ceph`, `monitoring`, `traefik`, `system`, etc.) so every later layer has a place to run.
2. **CRDs** – Monitoring CRDs (`ServiceMonitor`, `PodMonitor`, `PrometheusRule`) so any later Helm chart (Traefik, Rook, ESO, etc.) can create or reference them. Install Prometheus Operator CRDs (or CRD-only) right after namespaces.
3. **Storage (Rook/Ceph)** – So `StorageClass` and Ceph cluster exist before any workload that needs PVCs. NFS can be same layer or after Rook if it depends on it.
4. **External Secrets Operator** – ESO + `ClusterSecretStore` so secrets can be synced from the external backend.
5. **Secrets (ExternalSecret CRs)** – Sync secrets from Parameter Store/Vault so they exist before Traefik (e.g. CrowdSec), cert-manager (e.g. Cloudflare API), and apps.
6. **Infrastructure controllers** – Traefik, cert-manager (if Helm). These may create `ServiceMonitor` etc.; CRDs already exist from step 2.
7. **Infrastructure configs** – ClusterIssuers, IngressRoutes, Middleware, Certificates.
8. **Apps** – Everything that needs storage, secrets, and ingress.

So the Flux Kustomization dependency chain is:

**namespaces → crds → storage → eso → secrets → infra-controllers → infra-configs → apps.**

(You can fold “namespaces” into the CRDs layer if preferred, so the first Kustomization applies both.)

---

## 4. Target Flux layout (monorepo pattern)

Follow the [Flux repository structure](https://fluxcd.io/flux/guides/repository-structure/) and [flux2-kustomize-helm-example](https://github.com/fluxcd/flux2-kustomize-helm-example):

- **`clusters/<cluster-name>`** – Single source of truth for “what this cluster syncs.” Contains only Flux `Kustomization` CRs that reference the rest of the repo in the right order.
- **`infrastructure/`** – Split into layers that match the bootstrap order: namespaces, crds, storage, ESO, controllers, configs.
- **`apps/`** – Applications (and optionally `media/`), applied last with `dependsOn` on infra.

Flux-operator creates one `GitRepository` and one root `Kustomization` that applies **only** the path you set in `spec.sync.path` (e.g. `clusters/production`). That path must output the Flux `Kustomization` CRs that apply the rest of the repo in dependency order.

**Target structure:**

```
geekzoo-talos-prod/
├── clusters/
│   └── production/                    # Flux sync path (spec.sync.path)
│       ├── kustomization.yaml         # Builds Flux Kustomization CRs (in order)
│       ├── 00-namespaces.yaml         # Core namespaces (incl. monitoring, rook-ceph)
│       ├── 01-crds.yaml               # Monitoring CRDs (dependsOn: namespaces)
│       ├── 02-storage.yaml            # Rook/Ceph, NFS (dependsOn: 01-crds)
│       ├── 03-external-secrets.yaml   # ESO + ClusterSecretStore (dependsOn: 02-storage)
│       ├── 04-secrets.yaml            # ExternalSecret CRs (dependsOn: 03-external-secrets)
│       ├── 05-infra-controllers.yaml  # Traefik, cert-manager (dependsOn: 04-secrets)
│       ├── 06-infra-configs.yaml      # ClusterIssuers, IngressRoutes, etc. (dependsOn: 05)
│       └── 07-apps.yaml               # Apps + media (dependsOn: 06-infra-configs)
│
├── infrastructure/
│   ├── namespaces/                    # Core namespaces (incl. monitoring, rook-ceph)
│   ├── crds/                          # Monitoring CRDs only (ServiceMonitor, PodMonitor, PrometheusRule)
│   │   └── ...                        # Right after namespaces so all later Helm charts can use them
│   ├── storage/                       # Rook Ceph cluster + NFS (Helm/Kustomize)
│   │   ├── rook/
│   │   └── nfs/
│   ├── external-secrets/             # ESO HelmRelease + ClusterSecretStore
│   ├── controllers/                  # Traefik, cert-manager HelmReleases
│   └── configs/                      # ClusterIssuers, IngressRoutes, Middleware, Certificates
│
├── secrets/
│   └── external-secrets/             # ExternalSecret CRs only (synced after ESO)
│
├── apps/
│   ├── cloudflare/
│   └── ...
│
├── media/
│   └── jellyfin/
│
└── flux/
    ├── operator/
    └── instance/                      # FluxInstance with spec.sync added
```

Reconciliation order is enforced by `dependsOn` on each Flux Kustomization (see Section 6).

---

## 5. Monitoring layer: why and what to install

Many Helm charts and controllers emit or reference **monitoring CRDs**:

- **ServiceMonitor**, **PodMonitor** (Prometheus Operator) – used by Traefik, Rook, ESO, and others for scraping metrics.
- **PrometheusRule** – alerting/recording rules (Rook can create these if enabled).

If these CRDs are not present when a Helm release is applied, the release can fail or leave orphaned resources. So a **CRDs** layer runs **right after namespaces** (before storage and everything else), and infra controllers (Traefik, cert-manager, etc.) run later so the CRDs already exist.

Options:

- **Option A (recommended for bootstrap):** Install only the **CRDs** in `infrastructure/crds/` (e.g. from the prometheus-operator chart with `crds.enabled: true` and no other resources, or a thin CRD-only manifest). Then install the full monitoring stack (Prometheus, Grafana, etc.) in a later layer or leave it to another process.
- **Option B:** Install **Prometheus Operator** (or **kube-prometheus-stack**) via Flux HelmRelease in `infrastructure/crds/`; that installs the CRDs and a minimal stack. Keep it lightweight so this layer stays "CRDs right after namespaces."
- **Option C:** If you use a different observability stack (e.g. Groundcover, Grafana Cloud agent) that registers these CRDs, apply it in this same **crds** layer (right after namespaces).

Your ExternalSecrets already reference a **`monitoring`** namespace (Grafana Cloud, Groundcover, Dash0). Ensure the **namespaces** layer (or the first layer that creates namespaces) includes **`monitoring`** so those secrets can be synced into it.

---

## 6. Step-by-step migration plan

### Phase 1 – Add cluster entrypoint and FluxInstance sync

**Goal:** Flux-operator syncs from this repo; root applies only `clusters/production`; that directory applies the rest in order.

1. **Create `clusters/production/`**
  - Add `kustomization.yaml` that includes the Flux `Kustomization` manifests (see Phase 2).
  - Add at least one Flux `Kustomization` (e.g. `infrastructure.yaml`) pointing at `./infrastructure` so there is something to sync.
  - Use a cluster name that matches your choice of path (e.g. `production` → `path: "clusters/production"`).
2. **Update FluxInstance with `spec.sync`**
  - In `flux/instance/instance.yaml` add:
  - If the repo is private: create a Git credential secret in `flux-system` and set `pullSecret` to that name.
3. **Apply FluxInstance once**
  - Apply the updated `flux/instance/instance.yaml` (or apply from the repo after pushing).
  - Operator will create `GitRepository/flux-system` and `Kustomization/flux-system` targeting `path: clusters/production`.
  - Verify: `kubectl get gitrepository,kustomization -n flux-system` and that the root Kustomization becomes Ready.
4. **Bootstrap chicken-and-egg**
  - The FluxInstance itself can stay “manually applied” from this repo (you push the YAML, then run `kubectl apply -f flux/instance/instance.yaml` once per cluster), or be applied by a separate bootstrap process. What matters is that after that, **all other manifests** are applied by Flux from `clusters/production`.

---

### Phase 2 – Define Flux Kustomizations in `clusters/production/`

**Goal:** Root applies only Flux CRs; those CRs apply each layer in bootstrap order via `dependsOn`.

1. **`clusters/production/kustomization.yaml`**
   - List all Flux Kustomization manifests in order (so the root applies them in one go):
     ```yaml
     resources:
       - 00-namespaces.yaml
       - 01-crds.yaml
       - 02-storage.yaml
       - 03-external-secrets.yaml
       - 04-secrets.yaml
       - 05-infra-controllers.yaml
       - 06-infra-configs.yaml
       - 07-apps.yaml
     ```
   - Namespaces first, then CRDs, then storage and the rest.

2. **Bootstrap-order Kustomizations** (each is a Flux `Kustomization` CR):
   - **00-namespaces.yaml** – `path: ./infrastructure/namespaces`. No `dependsOn`.
   - **01-crds.yaml** – `path: ./infrastructure/crds`. `dependsOn: [namespaces]`. Monitoring CRDs (ServiceMonitor, PodMonitor, PrometheusRule) so all later Helm charts can use them.
   - **02-storage.yaml** – `path: ./infrastructure/storage`. `dependsOn: [crds]`. Rook/Ceph, NFS.
   - **03-external-secrets.yaml** – `path: ./infrastructure/external-secrets`. `dependsOn: [storage]`.
   - **04-secrets.yaml** – `path: ./secrets/external-secrets`. `dependsOn: [external-secrets]`. So ExternalSecret CRs reconcile after ESO and ClusterSecretStore exist.
   - **05-infra-controllers.yaml** – `path: ./infrastructure/controllers`. `dependsOn: [secrets]`. Traefik, cert-manager; they can use synced secrets and the CRDs from 01-crds.
   - **06-infra-configs.yaml** – `path: ./infrastructure/configs`. `dependsOn: [infra-controllers]`. ClusterIssuers, IngressRoutes, Middleware, Certificates.
   - **07-apps.yaml** – `path: ./apps` (and optionally `./media` via a single kustomization that includes both, or a separate Flux Kustomization for media). `dependsOn: [infra-configs]`.

3. **Naming:** Use consistent `metadata.name` values (e.g. `namespaces`, `crds`, `storage`, `external-secrets`, `secrets`, `infra-controllers`, `infra-configs`, `apps`) so `dependsOn` references match.

---

### Phase 3 – Restructure into `infrastructure/`

**Goal:** All cluster add-ons live under `infrastructure/` in layers that match the bootstrap order; CRDs run right after namespaces, then storage and the rest.

1. **`infrastructure/namespaces/`** – Move `namespaces/namespaces.yaml` here. Add **`monitoring`** namespace so ExternalSecrets that target `namespace: monitoring` (Grafana Cloud, Groundcover, Dash0) can sync in layer 04-secrets. Applied by 00-namespaces.
2. **`infrastructure/crds/`** – Add monitoring CRDs (ServiceMonitor, PodMonitor, PrometheusRule) only, e.g. Prometheus Operator CRD-only or thin manifest. See Section 5. Applied by 01-crds right after namespaces.
3. **`infrastructure/storage/`** – Move `storage/rook/` and `storage/nfs/` here. If the Rook operator is not installed by Omni, add it first (e.g. HelmRelease), then the Ceph cluster; NFS PV/PVC can be in the same path. StorageClasses and volumes must exist before apps.
4. **`infrastructure/external-secrets/`** – ESO HelmRelease + ClusterSecretStore (from `secrets/external-secrets-operator/config.yaml`). ExternalSecret CRs stay under `secrets/external-secrets/` (layer 04-secrets).
5. **`infrastructure/controllers/`** – Traefik (HelmRepository + HelmRelease, no helm-rendered.yaml), cert-manager if Helm. Move Traefik CRs (IngressRoute, Middleware, Certificate) to `infrastructure/configs/traefik/`.
6. **`infrastructure/configs/`** – ClusterIssuers, Traefik IngressRoutes/Middleware/Certificates. Applied after controllers.

---

### Phase 4 – Apps and optional layers

**Goal:** Apps (and optional media) are applied last, with `dependsOn: [infra-configs]`.

1. **Apps** – Keep `apps/cloudflare/` as-is. Ensure **07-apps.yaml** points at `./apps` (and optionally `./media` via a single kustomization that includes both, or a separate Flux Kustomization for media). Add a top-level `apps/kustomization.yaml` that includes `./cloudflare` and any other app dirs.
2. **Secrets**
  – Already a dedicated layer **04-secrets** with `path: ./secrets/external-secrets` and `dependsOn: [external-secrets]`. No change.
3. **Storage**
  – Already layer **01-storage** with `path: ./infrastructure/storage`; Rook and NFS live under `infrastructure/storage/`.

---

### Phase 5 – Traefik: HelmRelease instead of pre-rendered YAML

**Goal:** No more `helm-rendered.yaml`; Flux’s helm-controller manages Traefik.

1. In `infrastructure/controllers/traefik/`:
  - Add `HelmRepository` (or use OCI if you prefer):
  - Add `HelmRelease` with `chart.spec.chart: traefik`, `sourceRef` to the HelmRepository, and `values` from your current `traefik/helm-values.yaml`.
  - Pin version in the HelmRelease (e.g. `chart.spec.version: "37.2.0"`) for stability; you can relax to semver later.
2. Remove from the repo (or stop generating):
  - `traefik/helm-rendered.yaml`
  - Any Kustomize reference to it.
3. Move only the “config” CRs (IngressRoute, Middleware, Certificate) into `infrastructure/configs/traefik/` as in Phase 3.

---

### Phase 6 – Validation and cutover

1. **Pre-merge checks**
  - Run `kubectl kustomize build clusters/production` and ensure it outputs only Flux Kustomization CRs.
  - Run `kubectl kustomize build infrastructure` (and `apps`, `media`, etc.) and ensure no broken references or missing files.
  - Optionally add CI (e.g. GitHub Actions) with `kubeconform` or `kustomize build` to validate on every PR.
2. **Private repo and credentials**
  - If the repo is private, create the Git secret in `flux-system` and set `spec.sync.pullSecret` in the FluxInstance.
  - Prefer deploy keys or GitHub App over personal tokens for production.
3. **Cutover**
  - Do the restructure in a branch; merge when ready.
  - Ensure FluxInstance is updated (sync path + URL/ref) and applied.
  - Watch `kubectl get kustomizations -n flux-system -w` and fix any dependency or path errors.
  - Once root and child Kustomizations are Ready, the cluster state is fully driven by Flux; stop applying manifests manually for Flux-managed paths.
4. **Exclusions**
  - Do **not** put under Flux: `omni/`, sensitive bootstrap secrets (e.g. ESO AWS credentials if stored outside Git), or anything that must stay manual by policy. Document these in this file or in a RUNBOOK.

---

## 7. Sync order summary (bootstrap-able cluster)

| Order | Flux Kustomization | Path | Purpose |
| ----- | ------------------ | ----- | ------- |
| 0 | (root) | `clusters/production` | Applies Flux Kustomization CRs below |
| 1 | namespaces | `./infrastructure/namespaces` | Core namespaces (incl. monitoring, rook-ceph) |
| 2 | crds | `./infrastructure/crds` | Monitoring CRDs (ServiceMonitor, PodMonitor, PrometheusRule) right after namespaces |
| 3 | storage | `./infrastructure/storage` | Rook/Ceph, NFS – StorageClasses and PVCs |
| 4 | external-secrets | `./infrastructure/external-secrets` | ESO + ClusterSecretStore |
| 5 | secrets | `./secrets/external-secrets` | ExternalSecret CRs – sync secrets after ESO is ready |
| 6 | infra-controllers | `./infrastructure/controllers` | Traefik, cert-manager (HelmReleases) |
| 7 | infra-configs | `./infrastructure/configs` | ClusterIssuers, IngressRoutes, Middleware, Certificates |
| 8 | apps | `./apps` (+ optional `./media`) | Cloudflare, Jellyfin, etc. |

Each row (except root) has `dependsOn` on the previous layer so the cluster is fully bootstrap-able: **namespaces → crds → storage → ESO → secrets → controllers → configs → apps**.

---

## 8. FluxInstance sync reference

Minimal addition to `flux/instance/instance.yaml`:

```yaml
spec:
  distribution:
    version: "2.x"
    registry: "ghcr.io/fluxcd"
    artifact: "oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests"
  components:
    - source-controller
    - source-watcher
    - kustomize-controller
    - helm-controller
    - notification-controller
  cluster:
    type: kubernetes
    size: medium
    multitenant: false
    networkPolicy: true
    domain: "cluster.local"
  sync:
    kind: GitRepository
    url: "https://github.com/<org>/geekzoo-talos-prod"   # replace with real URL
    ref: "refs/heads/main"
    path: "clusters/production"
    # pullSecret: "flux-system"   # uncomment if private; create secret in flux-system
```

After applying this, the operator creates `GitRepository/flux-system` and root `Kustomization/flux-system`; Flux will sync only what’s under `clusters/production` and whatever those Kustomizations reference.

---

## 9. Checklist before going live

- Repo URL and branch in FluxInstance `spec.sync` are correct.
- If private: Git credential secret exists in `flux-system` and `pullSecret` is set.
- `clusters/production/` exists with numbered Flux Kustomizations (00-namespaces, 01-crds, 02-storage through 07-apps) and a kustomization that lists them.
- Bootstrap order: namespaces → crds → storage → external-secrets → secrets → infra-controllers → infra-configs → apps (each with correct `dependsOn`).
- `infrastructure/namespaces/` includes **monitoring** namespace for ExternalSecrets that target it.
- `infrastructure/crds/` (monitoring CRDs) runs right after namespaces; `infrastructure/storage/` (Rook, NFS) builds.
- ESO + ClusterSecretStore in `infrastructure/external-secrets/`; ExternalSecret CRs in `secrets/external-secrets/` (layer 04-secrets).
- Infrastructure controllers and configs paths build (Traefik HelmRelease, cert-manager, ClusterIssuers, IngressRoutes).
- Apps path exists and builds (cloudflare, media/jellyfin or equivalent).
- Traefik no longer depends on `helm-rendered.yaml`; HelmRelease is used.
- FluxInstance applied once; root Kustomization becomes Ready.
- Manual apply of non-Flux resources (e.g. omni, bootstrap secrets) documented and not overwritten by Flux.

---

## 10. References

- [Flux repository structure](https://fluxcd.io/flux/guides/repository-structure/)
- [flux2-kustomize-helm-example](https://github.com/fluxcd/flux2-kustomize-helm-example) (including Flux Operator bootstrap)
- [Flux Operator – Cluster sync](https://fluxoperator.dev/docs/instance/sync/)
- [Flux Kustomization dependsOn](https://fluxcd.io/flux/components/kustomize/kustomizations/#dependency-ordering)
- [FluxInstance CRD](https://fluxoperator.dev/docs/crd/fluxinstance/)

