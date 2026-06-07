#!/usr/bin/env zsh
set -euo pipefail

REQUESTS="${REQUESTS:-60}"
WAIT_SECONDS="${WAIT_SECONDS:-75}"
PROBE_NAMESPACE="${PROBE_NAMESPACE:-default}"
PROBE_IMAGE="${PROBE_IMAGE:-curlimages/curl:8.15.0}"
LOCAL_METRICS_PORT="${LOCAL_METRICS_PORT:-18428}"
POD_NAME="groundcover-workload-probe-$$"
PORT_FORWARD_LOG="/tmp/${POD_NAME}-port-forward.log"

services=(
  "adguard|http://adguard-svc.apps.svc.cluster.local:3000/"
  "authentik-server|http://authentik-server.identity.svc.cluster.local/"
  "bazarr|http://bazarr-svc.media.svc.cluster.local:6767/"
  "jellyfin|http://jellyfin-svc.media.svc.cluster.local:8096/"
  "lingarr|http://lingarr-svc.media.svc.cluster.local:9876/"
  "open-webui|http://open-webui-svc.apps.svc.cluster.local:8080/"
  "prowlarr|http://prowlarr-svc.media.svc.cluster.local:9696/"
  "qbittorrent|http://qbittorrent-svc.media.svc.cluster.local:8080/"
  "radarr|http://radarr-svc.media.svc.cluster.local:7878/"
  "sabnzbd|http://sabnzbd-svc.media.svc.cluster.local:8080/"
  "seerr|http://seerr.media.svc.cluster.local:5055/"
  "sonarr|http://sonarr-svc.media.svc.cluster.local:8989/"
  "vaultwarden|http://vaultwarden-svc.apps.svc.cluster.local/"
)

cleanup() {
  if [[ -n "${PORT_FORWARD_PID:-}" ]]; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi
  kubectl -n "${PROBE_NAMESPACE}" delete pod "${POD_NAME}" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

probe_script='
set -eu
request_count="${REQUESTS:-60}"

probe() {
  name="$1"
  url="$2"
  ok=0
  fail=0
  i=1
  while [ "$i" -le "$request_count" ]; do
    if curl -kfsS -L --max-time 8 -o /dev/null "$url"; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
    fi
    i=$((i + 1))
  done
  printf "%-18s ok=%-4s fail=%-4s %s\n" "$name" "$ok" "$fail" "$url"
}
'

for service in "${services[@]}"; do
  name="${service%%|*}"
  url="${service#*|}"
  probe_script="${probe_script}
probe '${name}' '${url}'"
done

echo "Generating ${REQUESTS} requests per service from ${PROBE_NAMESPACE}/${POD_NAME}..."
kubectl -n "${PROBE_NAMESPACE}" run "${POD_NAME}" \
  --image="${PROBE_IMAGE}" \
  --restart=Never \
  --env="REQUESTS=${REQUESTS}" \
  --command -- sh -ceu "${probe_script}"

echo "Waiting ${WAIT_SECONDS}s for Groundcover to flush workload metrics..."
sleep "${WAIT_SECONDS}"

echo "Opening local port-forward to Groundcover VictoriaMetrics on :${LOCAL_METRICS_PORT}..."
kubectl -n groundcover port-forward svc/groundcover-victoria-metrics "${LOCAL_METRICS_PORT}:8428" >"${PORT_FORWARD_LOG}" 2>&1 &
PORT_FORWARD_PID="$!"

for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:${LOCAL_METRICS_PORT}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

vm_query() {
  local title="$1"
  local query="$2"

  echo
  echo "== ${title} =="
  if command -v jq >/dev/null 2>&1; then
    curl -fsS --get "http://127.0.0.1:${LOCAL_METRICS_PORT}/api/v1/query" \
      --data-urlencode "query=${query}" | jq -r '
        if .status != "success" then
          .
        else
          .data.result[]
          | {
              metric: .metric,
              value: .value[1]
            }
        end'
  else
    curl -fsS --get "http://127.0.0.1:${LOCAL_METRICS_PORT}/api/v1/query" \
      --data-urlencode "query=${query}"
  fi
}

workload_match="adguard|authentik-server|bazarr|jellyfin|lingarr|open-webui|prowlarr|qbittorrent|radarr|sabnzbd|seerr|sonarr|vaultwarden"

vm_query "Workload request increases, grouped by role and type" \
  "sum by (namespace, workload, workload_name, role, type, status_code, return_code) (increase(groundcover_workload_total_counter{workload=~\"${workload_match}\"}[30m]))"

vm_query "Workload error increases" \
  "sum by (namespace, workload, workload_name, role, type, status_code, return_code) (increase(groundcover_workload_error_counter{workload=~\"${workload_match}\"}[30m]))"

vm_query "Observed workload latency series" \
  "max by (namespace, workload, workload_name, role, type, status_code, return_code) (max_over_time(groundcover_workload_latency_seconds{workload=~\"${workload_match}\"}[30m]))"

vm_query "Sensor HTTP parser backlog/unpaired indicators" \
  "{__name__=~\"flora_.*|groundcover_.*parser.*|groundcover_.*backlog.*\"}"
