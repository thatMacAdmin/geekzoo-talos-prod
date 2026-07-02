# AGENTS.md — geekzoo-talos-prod

GitOps repo for the `geekzoo-prod` Talos Kubernetes cluster (Omni-managed). Flux reconciles everything in this repo from `refs/heads/main`. There is **no application code** here — every file is a Kubernetes manifest, Helm release, Kustomization, Omni patch, or ESO secret reference.

Domain: `macbytes.io`. Cluster context: `geekzoo-geekzoo-prod`. Single environment: production.

---

## Agent operating principles

**Role:** Senior infrastructure engineer and full-stack developer with deep expertise in GitOps, Kubernetes, Flux CI/CD, OWASP security principles, and general vulnerability detection and mitigation. Ensure every manifest, Helm release, and change proposed here is well structured, carefully reviewed, and fact-based. Find the facts before suggesting anything — if something is genuinely unknown, say "I don't know" and go find the answer rather than guessing.

**Care & review:** Review anything before suggesting or publishing it. Suggestions must be fact-based; never speculate. Confirm before destructive or irreversible operations (see cardinal rule §0).

### Skill usage (always apply when applicable)

- **caveman** — Use as often as possible. Default to terse, high-signal output that drops filler while keeping full technical accuracy.
- **grill-me** — Use when asked to **diagnose** an issue, problem, or bug, to fully understand the scope of the request before acting.
- **improve-codebase-architecture** — Use when asked to **review** the architecture or general shape of the repository, codebase, or project.
- **grill-me** — Use when asked to **develop a new feature** or addition to the project, to nail down requirements first.

### Conventions

Always understand the general style of the codebase (this file, existing manifests, naming, and label conventions in §3) and follow good programming conventions. Match existing patterns — don't introduce inconsistency.

---

## 0. Cardinal rules

1. **Never `kubectl apply` application or infrastructure manifests.** Commit to `main` and let Flux reconcile. `kubectl`/`flux` are for *observing* and *forcing reconciliation* only. (Exception: live debugging via `kubectl port-forward`, `kubectl logs`, `kubectl describe`.)
2. **Never commit secret values.** Real secrets live in **AWS SSM Parameter Store** under `/k3s-geekzoo/*` in `us-east-2`. The repo only contains `ExternalSecret` CRs that pull from there via the `secretstore-aws-parameter-store` ClusterSecretStore. The legacy SOPS/age config in `.sops.yaml` exists but is not the active path — ESO is.
3. **Never commit anything under `omni/*.yaml`** except `omni/patches/*.yaml`. Omni-exported configs contain machine secrets; `.gitignore` already excludes them but double-check before staging.
4. **Bootstrap order is load-bearing.** The numeric prefix on `clusters/production/NN-*.yaml` files (`00-namespaces` → `13-mail`) is the Flux `dependsOn` chain. Adding a new top-level area means choosing the right slot and wiring `dependsOn` correctly in `clusters/production/`.
5. **DNS-split trap (mail):** `mail.macbytes.io`, `imap.*`, `smtp.*` are **DNS-only / grey-cloud** (raw TCP to frps). `dav.`, `webmail.`, `autoconfig.`, `autodiscover.`, and Cloudflare-tunneled hostnames are **proxied / orange-cloud**. Flipping `mail.` to proxied silently breaks IMAP/SMTP.

---

## 1. Bootstrap chain (clusters/production/)

Flux-operator syncs the path `clusters/production` from this repo. That directory contains only Flux `Kustomization` CRs; each one applies a sibling tree with `dependsOn` to enforce order:

```
00-namespaces  →  02-cilium  →  03-storage  →  04-external-secrets
                                                       ↓
                                                  05-secrets
                                                       ↓
                                       06-infra-controllers
                                                       ↓
                                       07-infra-configs   ──┐
                                                       ↓    │
                                       10-databases     ────┤
                                                            ↓
                                                   08-apps, 09-media, 13-mail
                                       11-image-automation, 12-observability
```

Mental model when adding anything new:
- Needs a namespace? It must exist in `infrastructure/namespaces/namespaces.yaml`.
- Needs a CRD? The operator providing it must be in `infrastructure/controllers/` and applied before the consumer.
- Needs a secret? Add an `ExternalSecret` under `secrets/external-secrets/` (and a corresponding SSM parameter — done out-of-band).
- Needs storage? Pick `ceph-block` (RWO, Rook RBD), `ceph-filesystem` (RWX, CephFS), or `nfs` (NAS-backed, RWX, very large). See PVC patterns in `apps/vaultwarden/pvc.yaml` and `infrastructure/storage/nfs/`.

Note: there is **no `01-*.yaml`** in `clusters/production/` — the gap is intentional (CRDs slot was folded into other layers). Don't "fix" it by renumbering.

---

## 2. Repository layout

| Path | Purpose |
|---|---|
| `clusters/production/` | Flux `Kustomization` CRs that drive everything else. Edit here only when adding a new top-level area. |
| `flux/operator/`, `flux/instance/` | Flux Operator Helm values + `FluxInstance` CR. Sync source = this repo, branch `main`, path `clusters/production`. |
| `flux/secrets/` | Bootstrap secret (`flux-github-auth`) — applied once by hand before Flux can self-sync. |
| `infrastructure/namespaces/` | All cluster namespaces, with PSA labels (`media`, `observability`, `gpu-operator`, `rook-ceph` are `privileged`; the rest are cluster-default `restricted`). |
| `infrastructure/cilium/` | Cilium manifest (rendered from Helm — **do not regenerate ad-hoc**, this is the canonical copy installed via Talos inline-manifest + this Flux Kustomization). |
| `infrastructure/storage/` | `snapshot-controller` CRDs + controller, `rook` operator/cluster HelmReleases, `nfs` PV/PVC pairs (203Ti TrueNAS export). |
| `infrastructure/external-secrets/` | ESO Helm + `ClusterSecretStore` pointing at AWS SSM `us-east-2`. |
| `infrastructure/controllers/` | All operators: `cert-manager`, `cnpg-operator` + `barman-cloud` plugin, `gpu-operator`, `metrics-server`, `rabbitmq-cluster-operator`, `redis-operator`, `traefik`. |
| `infrastructure/configs/` | ClusterIssuers (`letsencrypt-prod`/`-staging`), CNPG `ObjectStore`s (Wasabi + AWS), Traefik dashboard/middleware/TrueNAS ingresses. |
| `infrastructure/image-automation/` | One `ImageRepository` + `ImagePolicy` per auto-updated image, plus `ImageUpdateAutomation` per top-level area (`apps`, `mail`, scanning `./apps`, `./mail` respectively). |
| `secrets/external-secrets-operator/` | `ClusterSecretStore` (duplicate of the infra one — applied at the secrets layer for ordering). |
| `secrets/external-secrets/` | One `ExternalSecret` per app-level secret, all pulling from `/k3s-geekzoo/...`. |
| `apps/` | User-facing apps in namespace `apps` (Vaultwarden, AdGuard, Authentik, Open-WebUI, Home Assistant, Vikunja, Minecraft, Bifrost, Website) **plus** Cloudflared tunnel (in namespace `system`). |
| `media/` | Arr-stack + Jellyfin + Seerr + qBittorrent in namespace `media`. |
| `mail/` | Stalwart mail server, frpc tunnel client, Bulwark webmail (namespace `mail`). |
| `databases/` | One CNPG `Cluster` per consuming app (`authentik-pg`, `seerr-pg`, `vaultwarden-pg`, `vikunja-pg`) + `redis` (Bitnami Helm) + `blocky-pg`. Each PG cluster has a sibling `ScheduledBackup` to Wasabi via the barman-cloud plugin. |
| `observability/` | MikroTik CRS518 syslog gateway, plus the Grafana stack (kube-prometheus-stack + Loki + Promtail) for cluster-wide metrics and log aggregation. |
| `omni/` | Talos/Omni configs. **Only `omni/patches/*.yaml` is tracked** — everything else is gitignored. Per-node patches are named `400-cm-<machine-uuid>.yaml`, `410-resolvers-<machine-uuid>.yaml`. |
| `cert-manager/` | Top-level ClusterIssuers (also referenced from `infrastructure/configs/cert-manager/`). |
| `docs/` | `FLUX-MIGRATION-PLAN.md` (history of how the repo got to its current shape) and `SELF-HOSTED-EMAIL-IMPLEMENTATION.md` (running implementation log for the mail stack — the source of truth for mail design decisions). |
| `scripts/` | One-off operator scripts (currently only `generate-whisper-subtitles.zsh`). Not run by the cluster. |

---

## 3. Conventions

### 3.1 Per-app directory layout
A typical app dir contains exactly one Kustomization plus a small set of standard files:

```
apps/<name>/
  kustomization.yaml      # lists the files below in apply order
  pvc.yaml                # if stateful
  deployment.yaml
  service.yaml
  ingress.yaml            # Traefik IngressRoute (CRD), NOT networking.k8s.io Ingress
  certificate.yaml        # cert-manager Certificate, referencing letsencrypt-prod
  pdb.yaml                # optional, for single-replica critical services
```

Order in `kustomization.yaml` is conventionally: `pvc → (config) → service → deployment → ingress → certificate → pdb`.

### 3.2 Labels (set on every Deployment + pod template)
```
app: <name>
app.kubernetes.io/name: <name>
app.kubernetes.io/instance: <name>
app.kubernetes.io/component: <role>      # e.g. web, llm-gateway, media-server, tunnel
app.kubernetes.io/part-of: <area>        # apps | media | mail | system | database
app.kubernetes.io/managed-by: kustomize
```
The matchLabels selector intentionally uses **only** `app: <name>` (not the full set) — keep it that way to avoid breaking rollouts.

### 3.3 PodSecurity
Pods run **restricted** by default: `runAsNonRoot: true`, `runAsUser: 65534` (or image-specific UID like nginx-unprivileged 101), `seccompProfile.type: RuntimeDefault`, `allowPrivilegeEscalation: false`, all capabilities dropped. Only namespaces explicitly labeled `pod-security.kubernetes.io/enforce: privileged` (`media`, `observability`, `gpu-operator`, `rook-ceph`) allow looser pods (Jellyfin uses `runtimeClassName: nvidia`; qBittorrent uses gluetun w/ NET_ADMIN; Prometheus node-exporter needs host filesystem/PID access; etc).

### 3.4 Ingress = Traefik IngressRoute, not k8s Ingress
All HTTPS routing uses `traefik.io/v1alpha1 / IngressRoute` on entrypoint `websecure`, with `tls.secretName` pointing at a cert-manager-issued secret in the same namespace. The certificate is requested by a sibling `cert-manager.io/v1 Certificate` referencing `ClusterIssuer/letsencrypt-prod` (Cloudflare DNS-01).

### 3.5 External exposure
Two paths, both terminating at Traefik:
- **LAN clients** hit Traefik directly (192.168.3.x VIP) — unthrottled.
- **Internet clients** go through the single `cloudflared` Deployment in namespace `system` (`apps/cloudflare/`), which is bandwidth-capped to 25 Mbit/s via `kubernetes.io/egress-bandwidth: "25M"` (enforced by Cilium Bandwidth Manager). New hostnames are added to `apps/cloudflare/cloudflared-config.yaml`. **One replica only** — the cap is per-pod.
- **Mail raw TCP** (25/587/465/993) bypasses Cloudflare entirely: GCP-hosted `frps` → `frpc` pod in `mail` namespace → Stalwart. See `docs/SELF-HOSTED-EMAIL-IMPLEMENTATION.md` for the full topology.

### 3.6 Image automation
- Pin a real tag in `image: foo/bar:1.2.3`.
- Append `# {"$imagepolicy": "flux-system:<name>-image-policy"}` on the same line if you want Flux to auto-bump it. The matching `ImagePolicy` + `ImageRepository` go in `infrastructure/image-automation/`.
- **Convention:** cloudflared and Stalwart are pinned *without* the marker (no auto-update). Most other workloads use the marker with a semver range policy.
- The `apps-image-updates` and `mail-image-updates` `ImageUpdateAutomation`s push directly to `main` as `flux-image-automation@macbytes.io`. Don't be surprised by commits with subjects like `chore(images): update app container images` appearing without a PR.

### 3.7 Helm via Flux
Pattern is always:
1. `helm-repository.yaml` → `source.toolkit.fluxcd.io/v1 HelmRepository`
2. `helm-release.yaml` → `helm.toolkit.fluxcd.io/v2 HelmRelease`
3. Big values files (`helm-values.yaml`, `values.yaml`, …) are injected as ConfigMaps via `configMapGenerator` with `disableNameSuffixHash: true`, then referenced from the HelmRelease via `valuesFrom: [{kind: ConfigMap, name: <foo>-values, valuesKey: values.yaml}]`.

Don't switch to `spec.values:` for non-trivial charts — keep the ConfigMap pattern for diff-ability.

### 3.8 Databases (CNPG)
- Cluster name embeds a date suffix (`-20260401`) — that's an artifact of the in-place restore-from-Wasabi rebuild done on that date. **Don't rename it** without also re-pointing the `barman-cloud` `serverName` and migrating WAL prefixes.
- `bootstrap.recovery.source` points at an `externalClusters` entry that reads from the *old* `serverName` (no date suffix). This is the live-cluster-from-prior-backup pattern; preserve it when standing up new PG clusters from a prior incarnation.
- Per-app user/password lives in `secrets/external-secrets/pg-app-user-<app>.yaml` (created by ESO).
- Backups: every `Cluster` has a sibling `ScheduledBackup` running daily, pushed to Wasabi via the `barman-cloud.cloudnative-pg.io` plugin (`ObjectStore/wasabi-object-store` in namespace `database`). An `aws-object-store` also exists but is currently unused in `ScheduledBackup`s.

### 3.9 Secrets pattern
Every `ExternalSecret` in `secrets/external-secrets/` uses:
```yaml
spec:
  refreshInterval: 24h
  secretStoreRef:
    name: secretstore-aws-parameter-store
    kind: ClusterSecretStore
  target:
    creationPolicy: Owner
  dataFrom:
    - extract:
        key: /k3s-geekzoo/<param-name>
```
Use `dataFrom.extract` for SSM SecureStrings containing JSON (keys become Secret keys). Use `data: [{secretKey, remoteRef: {key, property}}]` when pulling a single field.

### 3.10 Observability — Grafana stack

The observability stack is **fully open-source** and Flux-managed (unlike the previous Groundcover experiment). All components live under `observability/` in namespace `observability`:

| Component | Helm chart | Purpose |
|---|---|---|
| `kube-prometheus-stack/` | `prometheus-community/kube-prometheus-stack` | Prometheus (metrics, 15d retention, 50Gi ceph-block), Alertmanager (10Gi), Grafana (10Gi), node-exporter DaemonSet |
| `loki/` | `grafana/loki` | Log aggregation, single-binary mode (small cluster), 50Gi filesystem storage |
| `promtail/` | `grafana/promtail` | DaemonSet that ships container logs to Loki |

Grafana is exposed at `grafana.macbytes.io` via Traefik IngressRoute + cert-manager cert, and is added to the cloudflared tunnel config. The Loki datasource is pre-provisioned in Grafana via `additionalDataSources` in the KPS values.

**Grafana admin credentials** are pulled from AWS SSM at `/k3s-geekzoo/grafana-admin` (two properties: `username`, `password`) via `secrets/external-secrets/grafana-admin.yaml`. The SSM parameter must be created out-of-band.

**kube-prometheus-stack CRDs** are managed via `install.crds: CreateReplace` / `upgrade.crds: CreateReplace` in the HelmRelease — this is required because the chart ships many CRDs (PrometheusRule, ServiceMonitor, etc.) that Flux would otherwise not apply.

---

## 4. Commands

There is no build, lint, or test in this repo. Everything is YAML reconciled by Flux.

### 4.1 Observe state
```sh
flux get kustomizations -A
flux get helmreleases -A
flux get sources git -A
kubectl get gitrepository,kustomization,helmrelease -A
kubectl -n flux-system logs deploy/kustomize-controller --tail=200
```

### 4.2 Force reconciliation (after pushing to main)
```sh
flux reconcile source git flux-system
flux reconcile kustomization apps                # or any other kustomization name
flux reconcile helmrelease traefik -n traefik
```

### 4.3 Inspect rendered output without applying
```sh
kustomize build clusters/production
kustomize build apps/vaultwarden
```
Kustomize 5.x required (`kustomize version`). Some kustomizations use `configMapGenerator` over large values files — `kustomize build` handles this, plain `kubectl apply -k` may not in older versions.

### 4.4 Talos / Omni
```sh
export OMNICONFIG=/Users/edward/Projects/geekzoo-talos-prod/omni/omniconfig.yaml
export TALOSCONFIG=/Users/edward/Projects/geekzoo-talos-prod/omni/talosconfig.yaml
omnictl get clusters
talosctl -n <node> version
```
The local `./talosconfig` at repo root is a 25-byte placeholder — use the one under `omni/` instead.

### 4.5 Validate a manifest before commit
```sh
kustomize build apps/<name> | kubectl --dry-run=client apply -f -
```

---

## 5. Gotchas / non-obvious behaviors

- **`flux/secrets/flux-github-auth.yaml`** is the bootstrap GitHub PAT secret that Flux Operator needs to clone this repo. It's applied **once** by hand before Flux can self-reconcile; not re-applied by Flux itself (chicken/egg).
- **Cilium is installed twice on purpose.** Once by Talos as an `inlineManifest` in `omni/bootstrap/cluster_setup.yaml` (so the cluster comes up with networking), then again by Flux from `infrastructure/cilium/cilium.yaml` (so day-2 changes flow through GitOps). The post-bootstrap patch `omni/bootstrap/post-bootstrap-remove-cilium-inline-manifest.yaml` strips the inline copy *after* Flux takes over. Do not edit one without understanding the other.
- **`commonLabels` in app kustomizations is being phased out** — `apps/bifrost/kustomization.yaml` still uses it. Prefer per-resource labels matching §3.2.
- **The `cluster.local` domain is hard-coded** in `flux/instance/instance.yaml` and various services. Don't change it without auditing the whole tree.
- **`ceph-block` is RWO**, `ceph-filesystem` is RWX. Most PVCs in this repo use `ceph-block`. NFS PVCs use `storageClassName: nfs` and bind to the static PVs in `infrastructure/storage/nfs/` by label selector (`app: apps-nfs` / `app: media-nfs`).
- **`runtimeClassName: nvidia`** (Jellyfin) requires the GPU operator to have finished installing the runtime. If a fresh cluster bootstrap fails on Jellyfin, give the GPU operator a few minutes and reconcile.
- **PVC for mail is in v1 backup scope** — Stalwart's data PVC holds mail+contacts+calendars and must be included in backups (currently only via Velero — confirm before destructive ops).
- **Stalwart `apply-job.yaml` is intentionally commented out** in `mail/stalwart/kustomization.yaml`. Provisioning runs live (`stalwart-cli apply --dry-run` then real). Don't uncomment without re-validating the plan schema against the running binary.
- **Git pushes from the cluster** (image automation) commit as `flux-image-automation@macbytes.io`. When investigating "who touched this file last," check the commit author — auto-bumps don't go through a human.
- **`.claude/` is in `.gitignore`** but `.claude/settings.local.json` exists locally with a large pre-approved bash allowlist. New tooling that needs cluster access can be added there without polluting the repo.
- **`seerr-chart-3.3.0.tgz`** and `vaultwarden-db-backup-20260401-101234.dump` at the repo root are residue from past one-off operations — ignored by `.gitignore`, safe to ignore.
- **No `dependsOn` on `apps`/`media`/`mail` for `image-automation`.** Image automation runs independently and only mutates files on `main`; the resulting commit re-triggers the normal Flux sync.
- **kube-prometheus-stack CRDs need `CreateReplace`.** The HelmRelease for KPS uses `install.crds` / `upgrade.crds: CreateReplace` because the chart bundles many CRDs. Don't switch this to `Skip` or monitoring rules will silently stop being applied.
- **Loki runs in single-binary mode** (1 replica, filesystem storage) because this is a small cluster. Don't switch to distributed mode (backend/read/write replicas) without also configuring object storage and bumping resources.
- **Authentik requires sequential minor-version upgrades.** See `apps/authentik/UPGRADE.md` — never jump more than one minor version at a time (e.g., 2025.10 → 2025.12 → 2026.2), and back up PostgreSQL before each hop.
- **Grafana admin password requires an SSM parameter.** The `grafana-admin` ExternalSecret reads `/k3s-geekzoo/grafana-admin` (properties: `username`, `password`). Create it in AWS SSM out-of-band or Grafana won't start.

---

## 6. When in doubt

- Mail design questions → `docs/SELF-HOSTED-EMAIL-IMPLEMENTATION.md` (decisions log + phase plan).
- "Why is the repo structured this way?" → `docs/FLUX-MIGRATION-PLAN.md` (bootstrap-order rationale).
- Cluster-side debugging → `kubectl`, `flux`, `talosctl`, `omnictl`.
- A workload won't reconcile → check `flux events -A` and the relevant controller logs in `flux-system` before touching manifests.
