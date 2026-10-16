#!/bin/bash

set -e

cd "$(dirname "$0")"

LOG_FILE="microk8s_test_$(date +%Y%m%d_%H%M%S).log"

# Display output on screen and save it to the log file.
exec > >(tee -a "$LOG_FILE") 2>&1

run_cmd() {
    echo
    echo "+ $*"
    "$@"
}

http_code() {
    local body_file="$1"
    local url="$2"
    local code
    code="$(curl -sS -o "$body_file" -w '%{http_code}' --ipv4 --connect-timeout 3 --max-time 8 "$url" || true)"
    if [ -z "$code" ]; then
        code="000"
    fi
    printf '%s' "$code"
}

PROM_PORT=19090
GRAFANA_PORT=13000
ALERT_PORT=19093
LOKI_PORT=13100
FLASK_PID=""
PF_PIDS=()

cleanup() {
    if [ -n "${FLASK_PID}" ]; then
        kill "${FLASK_PID}" >/dev/null 2>&1 || true
    fi
    local pid
    for pid in "${PF_PIDS[@]}"; do
        kill "${pid}" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

svc_name() {
    local selector="$1"
    local fallback="$2"
    local name
    name="$("${KUBECTL[@]}" -n observability get svc -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "$name" ]; then
        name="$fallback"
    fi
    if ! "${KUBECTL[@]}" -n observability get svc "$name" >/dev/null 2>&1; then
        echo "ERROR: service ${name} not found in namespace observability" >&2
        "${KUBECTL[@]}" -n observability get svc >&2 || true
        exit 1
    fi
    printf '%s' "$name"
}

forward_svc() {
    local local_port="$1"
    local selector="$2"
    local fallback="$3"
    local remote_port="$4"
    local name
    name="$(svc_name "$selector" "$fallback")"
    echo
    echo "+ ${KUBECTL[*]} -n observability port-forward --address 127.0.0.1 svc/${name} ${local_port}:${remote_port}"
    "${KUBECTL[@]}" -n observability port-forward --address 127.0.0.1 "svc/${name}" "${local_port}:${remote_port}" >"/tmp/task3_pf_${local_port}.log" 2>&1 &
    PF_PIDS+=("$!")
}

wait_http() {
    local url="$1"
    local _
    for _ in $(seq 1 60); do
        if curl -fsS --ipv4 --connect-timeout 2 --max-time 3 "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "ERROR: ${url} did not become ready"
    local port="${url#http://127.0.0.1:}"
    port="${port%%/*}"
    cat "/tmp/task3_pf_${port}.log" 2>/dev/null || true
    return 1
}

prom_value() {
    local query="$1"
    local body
    body="$(curl -fsS -G "http://127.0.0.1:${PROM_PORT}/api/v1/query" --ipv4 --max-time 8 --data-urlencode "query=${query}" || true)"
    printf '%s' "$body" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)
results = (data.get("data") or {}).get("result") or []
if not results:
    sys.exit(0)
number = float(results[0]["value"][1])
if number.is_integer():
    print(int(number))
else:
    print(results[0]["value"][1])
'
}

NGINX_REPLICAS='kube_deployment_status_replicas_available{namespace="task3",deployment="nginx"}'

wait_nginx_replicas() {
    local mode="$1"
    local value _
    for _ in $(seq 1 18); do
        echo
        echo "+ curl -fsS -G http://127.0.0.1:${PROM_PORT}/api/v1/query --data-urlencode query=${NGINX_REPLICAS}"
        value="$(prom_value "$NGINX_REPLICAS")"
        if [ -z "$value" ]; then
            echo "Prometheus value: <none>"
        else
            echo "Prometheus value: ${value}"
        fi
        if [ "$mode" = "up" ] && [ "$value" = "1" ]; then
            return 0
        fi
        if [ "$mode" = "down" ] && { [ -z "$value" ] || [ "$value" = "0" ]; }; then
            return 0
        fi
        sleep 10
    done
    return 1
}

loki_nginx_line() {
    local start body
    start="$(date -u -d '30 minutes ago' +%s)000000000"
    body="$(curl -fsS -G "http://127.0.0.1:${LOKI_PORT}/loki/api/v1/query_range" --ipv4 --max-time 8 \
        --data-urlencode 'query={namespace="task3"}' \
        --data-urlencode "start=${start}" \
        --data-urlencode 'limit=50' || true)"
    printf '%s' "$body" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)
for stream in (data.get("data") or {}).get("result") or []:
    for _, line in stream.get("values") or []:
        if "GET /" in line:
            print(line)
            sys.exit(0)
'
}

wait_nginx_log() {
    local line _
    for _ in $(seq 1 18); do
        echo
        echo "+ curl -fsS -G http://127.0.0.1:${LOKI_PORT}/loki/api/v1/query_range --data-urlencode query={namespace=\"task3\"}"
        line="$(loki_nginx_line)"
        if [ -n "$line" ]; then
            echo "Loki log: ${line}"
            return 0
        fi
        echo "Loki log: <none>"
        sleep 10
    done
    return 1
}

show_observability() {
    "${KUBECTL[@]}" -n observability get pods,svc || true
}

echo "=== MicroK8s Test ==="
echo "Date: $(date)"
echo "Log:  $LOG_FILE"

if microk8s kubectl get ns >/dev/null 2>&1; then
    KUBECTL=(microk8s kubectl)
elif sudo microk8s kubectl get ns >/dev/null 2>&1; then
    KUBECTL=(sudo microk8s kubectl)
else
    echo "ERROR: microk8s is not ready. Run ./setup_microk8s.sh on Linux first."
    exit 1
fi

echo
echo "=== Choose the ingress class ==="
echo
echo "+ ${KUBECTL[*]} get ingressclass"
"${KUBECTL[@]}" get ingressclass
if "${KUBECTL[@]}" get ingressclass public >/dev/null 2>&1; then
    INGRESS_CLASS="public"
elif "${KUBECTL[@]}" get ingressclass nginx >/dev/null 2>&1; then
    INGRESS_CLASS="nginx"
else
    INGRESS_CLASS="$("${KUBECTL[@]}" get ingressclass -o jsonpath='{.items[0].metadata.name}')"
fi
if [ -z "$INGRESS_CLASS" ]; then
    echo "ERROR: no IngressClass found. Enable the ingress addon."
    exit 1
fi
echo "Ingress class: ${INGRESS_CLASS}"

echo
echo "=== Apply the nginx Service with zero replicas ==="
manifest="$(mktemp)"
sed "s/ingressClassName: public/ingressClassName: ${INGRESS_CLASS}/" k8s/nginx.yaml >"$manifest"
run_cmd "${KUBECTL[@]}" apply -f "$manifest"
rm -f "$manifest"

if ! python3 -c 'import flask' >/dev/null 2>&1; then
    echo
    echo "=== Install Flask ==="
    run_cmd sudo apt-get update
    run_cmd sudo apt-get install -y python3-flask
fi

echo
echo "=== Start the Python app ==="
KUBECTL="${KUBECTL[*]}" python3 app.py >"/tmp/task3_flask.log" 2>&1 &
FLASK_PID=$!

ready=0
for _ in $(seq 1 30); do
    if curl -fsS --ipv4 --connect-timeout 2 --max-time 5 http://127.0.0.1:8081/health >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
if [ "$ready" -ne 1 ]; then
    echo "ERROR: Python app did not start"
    cat /tmp/task3_flask.log
    exit 1
fi
run_cmd curl -fsS --ipv4 --connect-timeout 2 --max-time 5 http://127.0.0.1:8081/health

echo
echo "=== Connect to Prometheus, Grafana, Alertmanager, and Loki ==="
if ! "${KUBECTL[@]}" get deploy -n observability kube-prom-stack-grafana >/dev/null 2>&1; then
    echo "ERROR: observability is not installed. Run ./setup_monitoring.sh first."
    exit 1
fi
forward_svc "$PROM_PORT" "app.kubernetes.io/name=prometheus" "kube-prom-stack-kube-prome-prometheus" 9090
forward_svc "$GRAFANA_PORT" "app.kubernetes.io/name=grafana" "kube-prom-stack-grafana" 80
forward_svc "$ALERT_PORT" "app.kubernetes.io/name=alertmanager" "kube-prom-stack-kube-prome-alertmanager" 9093
forward_svc "$LOKI_PORT" "app=loki" "loki" 3100
wait_http "http://127.0.0.1:${PROM_PORT}/-/ready"
wait_http "http://127.0.0.1:${GRAFANA_PORT}/api/health"
wait_http "http://127.0.0.1:${ALERT_PORT}/-/ready"
wait_http "http://127.0.0.1:${LOKI_PORT}/ready"

echo
echo "=== Grafana lists the Prometheus and Loki datasources ==="
password="$("${KUBECTL[@]}" -n observability get secret kube-prom-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d | tr -d '\n')"
echo
echo "+ curl -fsS -u admin:*** http://127.0.0.1:${GRAFANA_PORT}/api/datasources"
datasources="$(curl -fsS --ipv4 --max-time 8 -u "admin:${password}" "http://127.0.0.1:${GRAFANA_PORT}/api/datasources")"
datasource_report="$(printf '%s' "$datasources" | python3 -c '
import json, sys
data = json.load(sys.stdin)
found = {}
for item in data:
    found.setdefault(item.get("type"), []).append(item.get("name") or "")
missing = [kind for kind in ("prometheus", "loki") if not found.get(kind)]
for kind in ("prometheus", "loki"):
    names = [name for name in found.get(kind, []) if name]
    if names:
        print("{}: {}".format(kind, ", ".join(names)))
if missing:
    print("MISSING " + ", ".join(missing))
    sys.exit(1)
')" || {
    echo "$datasource_report"
    echo "ERROR: Grafana is missing a Prometheus or Loki datasource"
    show_observability
    exit 1
}
echo "$datasource_report"
echo "PASS: Grafana datasources prometheus and loki"

echo
echo "=== Alertmanager is holding Prometheus alerts ==="
watchdog=0
for _ in $(seq 1 18); do
    echo
    echo "+ curl -fsS http://127.0.0.1:${ALERT_PORT}/api/v2/alerts"
    alerts="$(curl -fsS --ipv4 --max-time 8 "http://127.0.0.1:${ALERT_PORT}/api/v2/alerts" || true)"
    alert_names="$(printf '%s' "$alerts" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    data = json.loads(raw) if raw else []
except json.JSONDecodeError:
    data = []
if not isinstance(data, list):
    data = []
names = sorted({
    (item.get("labels") or {}).get("alertname", "")
    for item in data
    if isinstance(item, dict) and (item.get("labels") or {}).get("alertname")
})
print(", ".join(names))
')"
    if [ -z "$alert_names" ]; then
        echo "Alertmanager alerts: <none>"
    else
        echo "Alertmanager alerts: ${alert_names}"
    fi
    if printf '%s' "$alert_names" | grep -q "Watchdog"; then
        watchdog=1
        break
    fi
    sleep 10
done
if [ "$watchdog" -ne 1 ]; then
    echo "ERROR: Alertmanager did not return the Watchdog alert"
    show_observability
    exit 1
fi
echo "PASS: Alertmanager alert Watchdog"

echo
echo "=== Test 1: nginx is down, localhost should fail ==="
body="$(mktemp)"
echo
echo "+ curl -sS --ipv4 --connect-timeout 3 --max-time 8 http://localhost/"
code="$(http_code "$body" http://localhost/)"
echo "HTTP ${code}"
cat "$body" || true
echo
if [ "$code" = "200" ] && grep -q "Welcome to nginx" "$body"; then
    echo "ERROR: nginx page was served before spin-up"
    exit 1
fi
echo "PASS: HTTP ${code}, nginx page is not served"
if ! wait_nginx_replicas down; then
    echo "ERROR: Prometheus still reports an available nginx replica"
    show_observability
    exit 1
fi
echo "PASS: Prometheus reports nginx is not available"

echo
echo "=== Test 2: spin up nginx ==="
echo
echo "+ curl -fsS --ipv4 --max-time 180 http://127.0.0.1:8081/spin-up"
curl -fsS --ipv4 --max-time 180 http://127.0.0.1:8081/spin-up
echo

echo
echo "=== Test 3: localhost should return the nginx page ==="
ok=0
for _ in $(seq 1 20); do
    echo
    echo "+ curl -sS -D - --ipv4 --connect-timeout 3 --max-time 8 http://localhost/"
    code="$(http_code "$body" http://localhost/)"
    echo "HTTP ${code}"
    cat "$body" || true
    echo
    if [ "$code" = "200" ] && grep -q "Welcome to nginx" "$body"; then
        ok=1
        break
    fi
    sleep 2
done
if [ "$ok" -ne 1 ]; then
    echo "ERROR: nginx page was not served after spin-up"
    "${KUBECTL[@]}" -n task3 get pods,svc,ingress,endpoints
    exit 1
fi
echo "PASS: HTTP 200, Welcome to nginx"
if ! wait_nginx_replicas up; then
    echo "ERROR: Prometheus did not report one available nginx replica"
    show_observability
    exit 1
fi
echo "PASS: Prometheus reports 1 available nginx replica"
if ! wait_nginx_log; then
    echo "ERROR: Loki has no nginx GET / line for namespace task3"
    show_observability
    exit 1
fi
echo "PASS: Loki has the nginx GET / line"

echo
echo "=== Test 4: spin down nginx ==="
echo
echo "+ curl -fsS --ipv4 --max-time 180 http://127.0.0.1:8081/spin-down"
curl -fsS --ipv4 --max-time 180 http://127.0.0.1:8081/spin-down
echo

echo
echo "=== Test 5: localhost should fail again ==="
ok=0
for _ in $(seq 1 20); do
    echo
    echo "+ curl -sS --ipv4 --connect-timeout 3 --max-time 8 http://localhost/"
    code="$(http_code "$body" http://localhost/)"
    echo "HTTP ${code}"
    if [ "$code" != "200" ] || ! grep -q "Welcome to nginx" "$body"; then
        ok=1
        break
    fi
    sleep 2
done
rm -f "$body"
if [ "$ok" -ne 1 ]; then
    echo "ERROR: nginx page was still served after spin-down"
    exit 1
fi
echo "PASS: HTTP ${code}, nginx page is not served"
if ! wait_nginx_replicas down; then
    echo "ERROR: Prometheus still reports an available nginx replica after spin-down"
    show_observability
    exit 1
fi
echo "PASS: Prometheus reports nginx is not available"

echo
echo "=== Test complete ==="
echo "Log saved to: $LOG_FILE"
