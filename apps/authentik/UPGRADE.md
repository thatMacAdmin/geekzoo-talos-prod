# Authentik upgrade runbook (GitOps)

## Release sequence

Starting production baseline on 2026-10-11: application and Helm chart `2026.2.2`.
Final verified production version: application and Helm chart `2026.8.3`; no image override or obsolete Redis values remain.
Use sequential release lines, with the latest application patch in each line:

| Stage | Application | Helm chart | `values.global.image.tag` |
|---|---|---|---|
| 1 | `2026.2.7` | `2026.2.3` | `"2026.2.7"` |
| 2 | `2026.5.7` | `2026.5.6` | `"2026.5.7"` |
| 3 | `2026.8.3` | `2026.8.3` | Remove the override; the chart defaults to the matching image. |

The intermediate application patches have no matching published Helm chart.
Keep exact versions throughout the upgrade; do not enable automatic release-line upgrades.
Server, worker, and embedded outpost must run the same application version.

Sources:
- [Upgrade requirements](https://docs.goauthentik.io/install-config/upgrade/)
- [2026.5 release notes](https://docs.goauthentik.io/releases/2026.5/)
- [2026.8 release notes](https://docs.goauthentik.io/releases/2026.8/)
- [Helm chart index](https://charts.goauthentik.io/index.yaml)

## Preflight

- Use the explicit service-account kubeconfig for every cluster-connected command:
  `--kubeconfig /Users/edward/.kube/omni-sa-config.yaml`.
- Reserve a maintenance window: one server and one worker do not guarantee uninterrupted login.
- Confirm independent cluster access, PostgreSQL health, and a working normal admin/passkey/password login before the first hop.
- Inventory providers and outposts. The verified inventory has only the embedded proxy outpost; Grafana and Open WebUI are configured OIDC consumers.
- Preserve `authentik-secret-key`, `authentik-database-config`, `authentik-s3-storage`, the `authentik-storage` bucket, and the passkey-first login blueprint.
- Never export Secret values into Git, logs, or an unencrypted namespace snapshot.

## Backup and deploy each stage

1. Add a uniquely named `postgresql.cnpg.io/v1` Backup to `databases/authentik-pg/upgrade-backups.yaml`, using `method: plugin` and `barman-cloud.cloudnative-pg.io`. Annotate it with the currently deployed application version.
2. Commit and obtain operator approval before pushing. Reconcile the `databases` Kustomization through Flux; do not apply application or backup manifests directly.
3. Wait for `status.phase: completed`. Record the backup ID, timestamps, beginning/ending LSN and WAL names.
4. Verify Wasabi contains the backup's `backup.info` with `status=DONE`, its data archive, and both required boundary WAL segments. A Backup CR marked completed alone is not sufficient proof.
5. Preserve the existing archive server name `authentik-pg-cluster-geekzoo-prod-20260401`. The older bootstrap recovery source is not the source for these new pre-upgrade backups.
6. Render the full Authentik chart using the proposed HelmRelease values and preview its server-side diff. Verify server/worker images, readiness probes, database references, RBAC, and disabled bundled PostgreSQL.
7. Set the stage's chart/image pair in `apps/authentik/helm-release.yaml`. Use a `15m` timeout and `upgrade.strategy.name: RetryOnFailure` so a timeout does not automatically downgrade a migrated database.
8. Commit, obtain push approval, and reconcile the `apps` Kustomization and Authentik HelmRelease through Flux.
9. Watch rollout and migration progress. Investigate a stalled rollout rather than waiting silently for the timeout.
10. Pass every verification gate below before creating the next stage's fresh backup or pushing its upgrade.

Backup CRs are audit records, not indefinite recovery guarantees. The Wasabi ObjectStore retains backups for 30 days; verify the selected backup and WAL still exist before any restore.

## Verification gates

- HelmRelease Ready; server and worker Ready on the intended application image.
- Migrations completed; no pending migrations or new unexplained migration failures.
- PostgreSQL remains healthy with three ready instances and continuous WAL archiving.
- `https://authentik.macbytes.io/-/health/ready/` returns HTTP 200.
- Fresh normal login verifies the passkey-first flow, password fallback, and configured MFA. A recovery key or retained browser session does not prove this.
- Admin interface loads, and critical SSO consumers complete authorization and callback flows. Exercise each active protocol, including proxy/SAML where configured.
- Embedded outpost connects, WebSockets work, worker tasks run, the login blueprint reconciles, and S3 branding/assets load.
- Compare task errors with the baseline: 2026.8 exposes errors that older releases could hide.

For 2026.5, verify effective listener bindings and IPv4 reachability; the upstream default changes to `[::]` and the worker entrypoint changes to Rust.
For 2026.8, verify Traefik's direct peer addresses are trusted and forwarded headers preserve HTTPS, redirects and client addresses over both LAN and Cloudflare paths. Never trust `0.0.0.0/0` to suppress proxy errors.

## Recovery: no Helm-only rollback after migrations

1. Stop the sequence if any verification gate fails. Suspend the Authentik HelmRelease while investigating; do not automatically revert its image.
2. Quiesce Authentik writers before a database cutover. Prevent GitOps from restarting them during recovery.
3. Restore the immediately preceding stage's verified backup into an isolated CNPG cluster, reading from the existing Wasabi archive server name. Use a distinct archive destination/server name for the restored cluster's new WAL so recovery cannot overwrite the original backup chain.
4. Verify the restored database, then update Authentik's GitOps/ESO-managed database connection to the restored service.
5. Deploy the application and outpost versions matching that backup. Retain the original secret key and S3 credentials.
6. Resume reconciliation and repeat all verification gates before restoring normal service or considering another upgrade.

Database restoration and production connection cutover require operator approval. Do not delete the original PostgreSQL cluster, PVCs, secrets, or backups as part of an upgrade.

## Verified execution (2026-10-11)

| Application | Helm chart | Pre-upgrade Wasabi backup ID |
|---|---|---|
| `2026.2.7` | `2026.2.3` | `20261011T220112` |
| `2026.5.7` | `2026.5.6` | `20261011T223442` |
| `2026.8.3` | `2026.8.3` | `20261011T224926` |

For each recorded hop, the backup data archive and both boundary WAL segments were verified in Wasabi before deployment. Runtime checks covered migrations, worker health and completed tasks, the custom blueprint, public readiness, and all 11 configured OIDC discovery/JWKS endpoints. Providers without an asymmetric signing key intentionally publish no public signing keys.

The operator confirmed fresh login, admin access, and critical SSO checks after all three recorded hops. No recovery key was created.
Final checks also confirmed HTTP 200 and HTTPS OIDC issuers over explicit LAN and Cloudflare routes, unchanged Cloudflare SAML metadata, an established embedded-outpost WebSocket, and the rendered S3-hosted branding image.
The registered Jellyfin LDAP provider has no registered LDAP outpost; LDAP login was not asserted as verified.

## Redis decommission (completed)

- Authentik's Redis wiring was removed during the PostgreSQL-backed task migration.
- The unused Bitnami Redis release and both Redis ExternalSecrets were removed. The operator remains available for future instances.
- PVC retention was changed to `whenDeleted: Delete` / `whenScaled: Retain`, and all three replica PVC owner references were confirmed before uninstalling.
- Redis keys and all three 10Gi Ceph-backed replica PVCs were discarded with operator approval, without a backup. The AWS SSM parameter was retained.
