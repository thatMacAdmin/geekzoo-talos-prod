# AGENTS.md — geekzoo-talos-prod

GitOps repo for the `geekzoo-prod` Talos Kubernetes cluster (Omni-managed). Flux reconciles everything in this repo from `refs/heads/main`. There is **no application code** here — every file is a Kubernetes manifest, Helm release, Kustomization, Omni patch, or ESO secret reference.

Domain: `macbytes.io`. Cluster context: `geekzoo-geekzoo-prod`. Single environment: production.

---

## Agent operating principles

**Role:** Senior infrastructure engineer and full-stack developer with deep expertise in GitOps, Kubernetes, Flux CI/CD, OWASP security principles, and general vulnerability detection and mitigation. Ensure every manifest, Helm release, and change proposed here is well structured, carefully reviewed, and fact-based. Find the facts before suggesting anything — if something is genuinely unknown, say "I don't know" and go find the answer rather than guessing.

**Care & review:** Review anything before suggesting or publishing it. Suggestions must be fact-based; never speculate. Confirm before destructive or irreversible operations (see cardinal rule §0).

### Git workflow

- **Commit as you work.** When a logical unit of work is complete and tested, commit it. Don't accumulate a large uncommitted diff across unrelated changes. One commit per logical change.
- **Ask before pushing.** You are authorized to push to `main` (this is the live Flux source). Always ask the operator before running `git push` — say what you're about to push and why. Once the operator confirms, push.
- **Never force-push to `main`.**

### Skill usage (always apply when applicable)

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
6. **Use the saved local service-account credential explicitly.** Every cluster-connected `kubectl`, `flux`, or `helm` invocation MUST pass `--kubeconfig /Users/edward/.kube/omni-sa-config.yaml`, including commands launched from Python/JS tools or subprocesses. Do not rely on `KUBECONFIG`, the default kubeconfig, or the ambient current context; tool processes may have different environments. This kubeconfig authenticates as `m5_macbook_air@serviceaccount.omni.sidero.dev` and must remain outside Git. Interactive Omni authentication is only for specific operations this credential cannot authorize, or operations requiring a separate Omni identity: establish the actual authorization requirement and explain it to the operator before launching an auth dialog. A timeout is not evidence that interactive authentication is needed. Talos/Omni-specific operations continue to use the dedicated configs in §4.4.

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
| `apps/` | User-facing apps in namespace `apps` (Vaultwarden, AdGuard, Authentik, Open-WebUI, Home Assistant, Vikunja, Bifrost, Website) **plus** Cloudflared tunnel (in namespace `system`). |
| `media/` | Arr-stack + Jellyfin + Seerr + qBittorrent in namespace `media`. |
| `mail/` | Stalwart mail server, frpc tunnel client, Bulwark webmail (namespace `mail`). |
| `databases/` | One CNPG `Cluster` per consuming app (`authentik-pg`, `bifrost-pg`, `seerr-pg`, `vaultwarden-pg`, `vikunja-pg`) + `blocky-pg`. Each PG cluster has a sibling `ScheduledBackup` to Wasabi via the barman-cloud plugin. |
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
- **Convention:** Stalwart remains pinned *without* an image-policy marker (no auto-update). Cloudflared uses `cloudflared-image-policy` through `apps-image-updates`: stable numeric `YYYY.M.P` tags at or above `2026.10.0`, including future years; `latest`, prereleases, and variant tags are excluded. Keep Cloudflared's `no-autoupdate: true` so the binary does not self-update outside GitOps. Its one steady-state replica and 25 Mbit/s per-pod cap remain unchanged; the existing RollingUpdate can temporarily run two pods. To roll back, first suspend `apps-image-updates` or constrain the Cloudflared policy before reverting its image, otherwise automation can reapply the upgrade. Most other workloads use semver range policies.
- **Cloudflared private routing:** configure Private Routes targeting the tunnel in Cloudflare. Do not restore `warp-routing.enabled`; Cloudflared has not supported that flag since `2023.9.0`.
- The `apps-image-updates` and `mail-image-updates` `ImageUpdateAutomation`s push directly to `main` as `flux-image-automation@macbytes.io`. Don't be surprised by commits with subjects like `chore(images): update app container images` appearing without a PR.

### 3.7 Helm via Flux
Pattern is always:
1. `helm-repository.yaml` → `source.toolkit.fluxcd.io/v1 HelmRepository`
2. `helm-release.yaml` → `helm.toolkit.fluxcd.io/v2 HelmRelease`
3. Big values files (`helm-values.yaml`, `values.yaml`, …) are injected as ConfigMaps via `configMapGenerator` with `disableNameSuffixHash: true`, then referenced from the HelmRelease via `valuesFrom: [{kind: ConfigMap, name: <foo>-values, valuesKey: values.yaml}]`.

Don't switch to `spec.values:` for non-trivial charts — keep the ConfigMap pattern for diff-ability.

- **NVIDIA GPU Operator:** pinned to `v26.3.3` for Kubernetes 1.36 support (introduced in 26.3.2). Talos supplies the driver and toolkit: preserve `driver.enabled: false`, `toolkit.enabled: false`, and `hostPaths.driverInstallDir: /usr/local`. Keep the chart's pre-upgrade CRD hook enabled; verify ClusterPolicy readiness, GPU allocatable resources, and a real GPU workload after upgrades.
- **Traefik:** chart `41.7.1` with explicit binary pin `v3.7.14`; update both together. Chart 41 uses `service.spec.type`, `log` / `accessLog`, camelCase log fields, and object-valued file-provider content. Preserve dual-stack Cilium LoadBalancer IPs, HTTP/3, redirects, DaemonSet deployment, and ServiceMonitor. `install.crds` / `upgrade.crds: CreateReplace` updates bundled CRDs through Flux without deleting their resources.
- **cert-manager:** upgrade one minor at a time (`1.19` → `1.20.4` → `1.21.2` for Kubernetes 1.36). Keep `crds.enabled: true` so Helm upgrades its templated CRDs. Chart 1.21 removes the old configurable metrics port/path keys and controller self-tokenrequest RBAC; existing Cloudflare DNS-01 issuers need neither override.
- **External Secrets:** pinned to `2.12.0`, retaining `installCRDs: true` and the existing `external-secrets.io/v1` AWS Parameter Store consumers. Upstream recommends, but does not require, one-minor-at-a-time upgrades. This upgrade followed minor hops through 2.7, then an operator-approved direct 2.7 → 2.12 jump after reviewing all intervening changes. Kubernetes 1.35.9 with ESO 2.12 is operator-approved but outside published upstream test coverage (1.36 only). Verify fresh SSM sync of all 40 active ExternalSecrets and unchanged target Secret UIDs, owners, types, keys, and data; preserve normal refresh intervals.
- **Rook/Ceph:** operator and cluster charts are `1.21.0`; `ceph-csi-drivers` and the bundled CSI operator are `1.1.0`, with CSI explicitly pinned to `v3.17.1`. Upgrade order is operator → CSI drivers → cluster, enforced by HelmRelease dependencies. The 1.19 → 1.20 Helm migration requires Rook >=1.19.5 and moves driver configuration into the separate drivers chart. Preserve driver names, storage classes, and tuned resources. Rook 1.21 stops supplying default CSI image pins, so retain the explicit `csi.*` image settings and verify running pod images, not just the ImageSet ConfigMap. A ConfigMap correction alone did not roll the drivers during this upgrade; a temporary GitOps-declared CSI operator restart reconciled them.
- **Ceph security:** cluster and toolbox use `quay.io/ceph/ceph:v19.2.6-20260818`. Core CephX daemon keys were rotated with `security.cephx.daemon.keyRotationPolicy: KeyGeneration`, generation `2`, including MDS, RGW, and admin; metadata inspection confirmed AES256K core keys. CSI keys remain AES at generation `1` because current Talos kernels are `6.18`; AES256K kernel mounts require Linux 7.0+. Do not restrict allowed ciphers to AES256K or rotate CSI keys before kernel support. The operator-approved GitOps policy mutes only `AUTH_INSECURE_CLIENT_KEY_TYPE`, `AUTH_INSECURE_KEYS_ALLOWED`, `AUTH_INSECURE_KEYS_CREATABLE`, and `AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE`; core authentication errors and unrelated storage warnings remain visible. The rotating-service-key warning normally expires after 2–3 hours. Remove its mute after expiry; unmute the compatibility warnings after the Talos 1.15/Linux 7.x rollout, all remaining client-key and existing-mount migrations to AES256K, and cipher-policy hardening. Muting is a reporting policy, not an additional security fix. Core authentication health errors must clear before declaring the CVE resolved. See https://rook.io/docs/rook/v1.21/Storage-Configuration/Advanced/cephx-key-rotation/.
- **Storage upgrade checks:** the cluster HelmRelease uses a `20m` timeout for safe rolling daemon upgrades. Its post-renderer preserves immutable `ceph-block` parameters by removing four optional CSI parameters newly added by chart 1.21; do not delete/recreate a live StorageClass to bypass immutability. On 2026-10-11, RBD and CephFS passed original-data integrity, cross-node remount, fresh provisioning, and read/write checks after the Ceph upgrade and core-key rotation. Temporary probes, their four disposable volumes, and legacy CSI permission resources were removed afterward.

### 3.8 Databases (CNPG)
- Operator chart `0.29.1` runs CloudNativePG `1.30.1`; Barman Cloud is pinned to the upstream `v0.15.1` release manifest in `infrastructure/controllers/barman-cloud/`. Upgrade the operator first, then the plugin. Both can trigger database pod rolling updates; preserve the existing primary update policy and verify all three instances and two streaming replicas per cluster.
- PostgreSQL remains explicitly pinned to `17.6-system-trixie`; controller/plugin upgrades do not authorize changing database images, backup `serverName` values, recovery sources, or PVCs. On 2026-10-11, all five clusters completed fresh Wasabi backups with plugin version `0.15.1` and archived new WAL without additional failures. Restore was not exercised. Temporary GitOps Backup resources were removed afterward; object-store backup retention remains controlled by Barman.
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

### 3.11 Hawk GitHub Actions runners
Hawk's CI no longer runs in this cluster. It moved on 2026-10-28 to self-hosted runner VMs outside it (two Proxmox VMs and an OrbStack VM on the Mac Studio; see `build/ci-runner/` in the Hawk repo), and the ARC controller, scale set, `arc-system` and `hawk-runners` namespaces and their ExternalSecret were removed through GitOps. Privileged Docker-in-Docker CI should not come back to these nodes. Left behind on purpose: ARC's CRDs (Helm does not delete CRDs), SSM parameter `/k3s-geekzoo/hawk-runner-github`, and the `geekzoo-actions-runners` GitHub App.

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
- **Minecraft is decommissioned.** Its Helm release, world PVC/Ceph volume, values, chart source, and RCON ExternalSecret are removed. The shared `pvc-apps-nfs` / `pv-apps-nfs` and existing backup files are retained; the TrueNAS export path `/mnt/geekzoo/minecraft` is intentionally unchanged.
- **Bitnami Redis is decommissioned.** Its Helm release/source, Authentik Redis ExternalSecret, and database Redis password ExternalSecret are removed. The remaining keys and three 10Gi Ceph-backed replica PVCs are approved for deletion without a backup. Before removing the release, reconcile its replica PVC retention policy to `whenDeleted: Delete` and verify all three claims are owned by the replica StatefulSet. Keep the Redis operator for future declarative instances and retain the AWS SSM parameter; no Redis instances are currently operator-managed.
- **Inbox Zero is decommissioned.** Its web/worker/Redis-HTTP workloads, ingress, Certificate, tunnel route, dedicated CNPG cluster and backup schedule, and ExternalSecrets are removed. Deleting the CNPG cluster deletes its three owned Ceph-backed database PVCs. Bifrost remains; existing Wasabi backups, AWS SSM parameters, GCP OAuth/Pub/Sub resources, DNS records, and the unowned cert-manager TLS Secret are retained. The dated cluster audit remains historical evidence, not current topology. Restoring Inbox Zero requires restoring database backups and retaining the original encryption credentials; reverting manifests alone does not restore deleted data.
- **kube-state-metrics is pinned independently** at `v2.20.0` through `kube-state-metrics.image.tag` in the kube-prometheus-stack values. Keep the existing chart-selected collectors/RBAC; this image change does not upgrade Prometheus Operator. In 2.20, `kube_pod_status_reason` emits only the actual reason rather than zero-valued rows for every possible reason.
- **Snapshot stack is v8.6.0**: six upstream CRDs, snapshot-controller, and both Ceph CSI snapshotters. Apply/reconcile CRDs before upgrading controllers. Group snapshots serve GA `v1` while retaining `v1beta2` as the storage version; do not remove beta versions without checking stored objects. RBD and CephFS individual snapshot/restore data isolation was verified on 2026-10-12 using temporary GitOps-managed volumes, snapshots, and Jobs.
- **CSI image-set updates require a rollout with operator 1.1.0.** The 8.6 upgrade updated `rook-csi-operator-image-set-configmap` but existing Driver deployments retained 8.5, including after a forced drivers Helm reconciliation. The Rook HelmRelease post-renderer stamps `macbytes.io/csi-image-set-version` on the CSI operator pod template. Bump that annotation with future image-set changes, then verify the actual Driver deployment images—not just Helm readiness or the ConfigMap.

---

## 6. When in doubt

- Mail design questions → `docs/SELF-HOSTED-EMAIL-IMPLEMENTATION.md` (decisions log + phase plan).
- "Why is the repo structured this way?" → `docs/FLUX-MIGRATION-PLAN.md` (bootstrap-order rationale).
- Cluster-side debugging → `kubectl`, `flux`, `talosctl`, `omnictl`.
- A workload won't reconcile → check `flux events -A` and the relevant controller logs in `flux-system` before touching manifests.
