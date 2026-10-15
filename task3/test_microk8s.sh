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
export KUBECTL="${KUBECTL[*]}"

echo
echo "=== Choose the ingress class ==="
if "${KUBECTL[@]}" get ingressclass public >/dev/null 2>&1; then
    INGRESS_CLASS="public"
elif "${KUBECTL[@]}" get ingressclass nginx >/dev/null 2>&1; then
    INGRESS_CLASS="nginx"
else
    echo "ERROR: no public or nginx IngressClass found. Enable the ingress addon."
    "${KUBECTL[@]}" get ingressclass
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
python3 app.py >"/tmp/task3_flask.log" 2>&1 &
FLASK_PID=$!
trap 'kill "$FLASK_PID" >/dev/null 2>&1 || true' EXIT

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

echo
echo "=== Test complete ==="
echo "Log saved to: $LOG_FILE"
