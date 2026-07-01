# Groundcover

Groundcover is installed manually via the CLI, not via Flux.

## Installation

```bash
# 1. Namespace is created by Flux from infrastructure/namespaces/namespaces.yaml
# with privileged PodSecurity labels

# 2. Install Groundcover using helm (installed manually, not Flux):
helm repo add groundcover https://helm.groundcover.com && \
helm repo update && \
helm upgrade --install groundcover groundcover/groundcover \
  --namespace groundcover \
  --create-namespace=false \
  --values infrastructure/groundcover/values.yaml
```

## Important Notes

### Namespace Labels

The `groundcover` namespace is managed by Flux and has privileged PodSecurity labels:
- `pod-security.kubernetes.io/enforce: privileged`
- `pod-security.kubernetes.io/audit: privileged`
- `pod-security.kubernetes.io/warn: privileged`
- `pod-security.kubernetes.io/enforce-version: latest`

These are required for the eBPF sensor DaemonSet (needs `SYS_ADMIN`, `SYS_PTRACE`, hostPID, hostPath volumes).

### IPv6 Fix

The `values.yaml` includes `<prefer_ipv6>0</prefer_ipv6>` in ClickHouse's `extraOverrides` to force IPv4 DNS resolution. Without this, ClickHouse fails to connect to its embedded ZooKeeper on IPv6 addresses (`fd10:244:0:5::xxxx:2181`).

### Why Not in Flux?

Groundcover is managed outside Flux because:
1. It's a commercial SaaS product with credentials/tokens that shouldn't be committed
2. It's upgraded manually at your pace, not auto-updated by image automation
3. The installation is idempotent via `helm upgrade --install`

## Files

- `values.yaml` — Minimal cluster-specific overrides for your setup
- `defaults.yaml` — Full default values from the Groundcover chart (for reference)

## Cluster ID

Configured as `geekzoo-geekzoo-prod` to match your Omni cluster context.