# Log Enrichment — Tier 3 (Deferred)

Apps that still ship **raw unstructured logs** to Loki. Logs are collected by
Promtail (searchable by `namespace` / `pod` / `container`), but no `level` or
structured fields are extracted as labels.

Evaluate each after cluster is live — grab a log sample with
`kubectl -n <ns> logs deploy/<name> --tail=20` and add a `match` pipeline stage
to `observability/promtail/helm-values.yaml`.

## Low signal / unstructured

| App | Namespace | Image | Notes |
|-----|-----------|-------|-------|
| qbittorrent | media | `linuxserver/qbittorrent` | C++/Qt, no structured logging. Low value. |
| mousehole (sidecar) | media | `tmmrtn/mousehole` | Unknown format. Low traffic. Sample post-deploy. |
| sabnzbd | media | `linuxserver/sabnzbd` | Python, semi-structured. Chatty, low ROI. |
| lingarr | media | `lingarr/lingarr` | Unknown format. Sample post-deploy. |

## Needs live log sample to classify

| App | Namespace | Image | Notes |
|-----|-----------|-------|-------|
| bulwark | mail | `ghcr.io/bulwarkmail/webmail` | Likely Node/TS. Check if JSON-capable. |
| open-webui | apps | `ghcr.io/open-webui/open-webui` | Python/FastAPI. May support JSON via env var. |
| minecraft | apps | (Helm chart) | Java log4j. Multiline stack traces need `multiline` stage. |

## Out-of-band (config managed live, not GitOps)

| App | Namespace | Change needed | How |
|-----|-----------|---------------|-----|
| stalwart | mail | `log.format = "json"` | `stalwart-cli config set log.format json` via web admin or CLI. Config lives in RocksDB datastore, not in repo manifests. Once enabled, add `json` match stage to promtail. |
