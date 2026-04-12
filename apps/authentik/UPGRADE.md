# Authentik upgrade runbook (GitOps)

Last verified baseline in this repo:
`apps/authentik/helm-release.yaml` -> chart `2025.10.1`

Current manifest target after this change:
`apps/authentik/helm-release.yaml` -> chart `2025.12.2`

**Why staged:** Authentik requires sequential minor upgrades.

## 1) Preflight checklist

1. Backup PostgreSQL before every hop.
2. Snapshot namespace objects:
   - `kubectl -n identity get all,secret,cm,sa,sa -o yaml > /tmp/identity-pre-upgrade.yaml`
3. Verify outposts inventory and ensure any outposts are upgraded in the same release window.
4. Confirm no duplicate Authentik group names exist before upgrading to 2025.12.x.
5. Review custom property mappings/flows for `User.ak_groups` usage before entering 2026.2.x.
6. Remove any Authentik-specific Redis env wiring from the manifest:
   - `AUTHENTIK_REDIS__PASSWORD` removed.
   - `values.authentik.redis.host` removed.

## 2) Staged upgrade sequence

### Step A: 2025.10.x -> latest 2025.12.x
1. Temporarily set chart version to the latest `2025.12.x` in `apps/authentik/helm-release.yaml`.
2. Push/apply change and wait for `ak-server` and `ak-worker` to become healthy.
3. Run smoke checks:
   - login to admin
   - basic SSO flow
   - outpost connectivity (if any)
4. Re-run database backup after successful validation.

### Step B: 2025.12.x -> latest 2026.2.x
1. Set chart version to latest `2026.2.x` (`2026.2.2` at time of this change).
2. Push/apply change and wait for health.
3. Re-run smoke checks + SCIM/SSO checks.
4. Verify logs for migration/completion warnings.

## 3) Post-upgrade validation

1. Confirm no Redis settings remain in Authentik container env.
2. Validate auth endpoints, SCIM where enabled, OAuth/OIDC, and SAML flows.
3. Confirm storage paths/served content are working.
4. Verify worker/task queues and background jobs are processing.

## 4) Rollback

If a stage fails:

1. Revert the HelmRelease chart version to the previously working value.
2. Force reconcile to rollback the deployment.
3. Confirm pods return to steady state and run smoke checks again.

## 5) Optional cleanup

- If Redis is no longer used by Authentik, keep it for other workloads until verified, then remove associated Authentik references only.
- If Redis persistence exists only for Authentik, remove it after the 2025.10 migration is proven stable.
