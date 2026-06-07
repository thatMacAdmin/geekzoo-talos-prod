#!/usr/bin/env zsh
set -euo pipefail

REQUESTS="${REQUESTS:-60}"
WAIT_SECONDS="${WAIT_SECONDS:-75}"
PROBE_NAMESPACE="${PROBE_NAMESPACE:-default}"
PROBE_IMAGE="${PROBE_IMAGE:-curlimages/curl:8.15.0}"
CONTROL_NAMESPACE="${CONTROL_NAMESPACE:-default}"
CONTROL_APP="${CONTROL_APP:-groundcover-http-echo}"
CONTROL_IMAGE="${CONTROL_IMAGE:-hashicorp/http-echo:1.0}"
LOCAL_METRICS_PORT="${LOCAL_METRICS_PORT:-18428}"
POD_NAME="groundcover-workload-probe-$$"
PORT_FORWARD_LOG="/tmp/${POD_NAME}-port-forward.log"

services=(
  "groundcover-http-echo|http://${CONTROL_APP}.${CONTROL_NAMESPACE}.svc.cluster.local:8080/"
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
  "seerr|http://seerr.media.svc.cluster.local/"
  "sonarr|http://sonarr-svc.media.svc.cluster.local:8989/"
  "vaultwarden|http://vaultwarden-svc.apps.svc.cluster.local/"
)

cleanup() {
  if [[ -n "${PORT_FORWARD_PID:-}" ]]; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi
  kubectl -n "${PROBE_NAMESPACE}" delete pod "${POD_NAME}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${CONTROL_NAMESPACE}" delete service "${CONTROL_APP}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "${CONTROL_NAMESPACE}" delete deployment "${CONTROL_APP}" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Creating raw HTTP control workload ${CONTROL_NAMESPACE}/${CONTROL_APP}..."
kubectl -n "${CONTROL_NAMESPACE}" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${CONTROL_APP}
  labels:
    app.kubernetes.io/name: ${CONTROL_APP}
    app.kubernetes.io/instance: ${CONTROL_APP}
    app.kubernetes.io/component: http-control
    app.kubernetes.io/part-of: observability-validation
    groundcover.com/service: ${CONTROL_APP}
    groundcover.com/team: homelab
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${CONTROL_APP}
      app.kubernetes.io/instance: ${CONTROL_APP}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${CONTROL_APP}
        app.kubernetes.io/instance: ${CONTROL_APP}
        app.kubernetes.io/component: http-control
        app.kubernetes.io/part-of: observability-validation
        groundcover.com/service: ${CONTROL_APP}
        groundcover.com/team: homelab
    spec:
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: http-echo
          image: ${CONTROL_IMAGE}
          args:
            - -listen=:8080
            - -text=groundcover-http-ok
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            runAsNonRoot: true
            runAsUser: 65534
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            periodSeconds: 2
            failureThreshold: 15
---
apiVersion: v1
kind: Service
metadata:
  name: ${CONTROL_APP}
spec:
  selector:
    app.kubernetes.io/name: ${CONTROL_APP}
    app.kubernetes.io/instance: ${CONTROL_APP}
  ports:
    - name: http
      port: 8080
      targetPort: 8080
EOF

kubectl -n "${CONTROL_NAMESPACE}" rollout status deployment/"${CONTROL_APP}" --timeout=90s

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
kubectl -n "${PROBE_NAMESPACE}" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  labels:
    app.kubernetes.io/name: groundcover-workload-probe
    app.kubernetes.io/instance: ${POD_NAME}
    app.kubernetes.io/component: traffic-generator
    app.kubernetes.io/part-of: observability-validation
spec:
  restartPolicy: Never
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: curl
      image: ${PROBE_IMAGE}
      env:
        - name: REQUESTS
          value: "${REQUESTS}"
      command:
        - sh
        - -ceu
        - |
$(printf '%s\n' "${probe_script}" | sed 's/^/          /')
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
        runAsNonRoot: true
        runAsUser: 65534
EOF

kubectl -n "${PROBE_NAMESPACE}" wait --for=condition=Ready pod/"${POD_NAME}" --timeout=90s || true
kubectl -n "${PROBE_NAMESPACE}" logs -f pod/"${POD_NAME}"
kubectl -n "${PROBE_NAMESPACE}" wait --for=condition=Ready=false pod/"${POD_NAME}" --timeout=5s >/dev/null 2>&1 || true

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

workload_match="groundcover-http-echo|adguard|authentik-server|bazarr|jellyfin|lingarr|open-webui|prowlarr|qbittorrent|radarr|sabnzbd|seerr|sonarr|vaultwarden"

vm_query "Workload request increases, grouped by role and type" \
  "sum by (namespace, workload, workload_name, role, type, status_code, return_code) (increase(groundcover_workload_total_counter{workload=~\"${workload_match}\"}[30m]))"

vm_query "Workload error increases" \
  "sum by (namespace, workload, workload_name, role, type, status_code, return_code) (increase(groundcover_workload_error_counter{workload=~\"${workload_match}\"}[30m]))"

vm_query "Observed workload latency series" \
  "max by (namespace, workload, workload_name, role, type, status_code, return_code) (max_over_time(groundcover_workload_latency_seconds{workload=~\"${workload_match}\"}[30m]))"

vm_query "Sensor parser/drop warning summary" \
  "topk(40, sum by (__name__, instance, consumer, warning, error) ({__name__=~\"flora_chunk_streamer_error|flora_http.*|flora_http2.*|flora_.*parser.*|groundcover_.*parser.*|groundcover_.*backlog.*|flora_connection_manager_warnings_total|flora_uprober_error_total|flora_uprober_warning_total\"}))"
