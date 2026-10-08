#!/bin/bash

set -e

cd "$(dirname "$0")"

LOG_FILE="proxy_test_$(date +%Y%m%d_%H%M%S).log"

# Display output on screen and save it to the log file.
exec > >(tee -a "$LOG_FILE") 2>&1

# Print the command, run it, and leave its output in the log.
run_cmd() {
    echo
    echo "+ $*"
    "$@"
}

echo "=== Reverse Proxy Test ==="
echo "Date: $(date)"
echo "Log:  $LOG_FILE"

echo
echo "=== Clean up previous Task 2 environment ==="
run_cmd docker compose down --remove-orphans

echo
echo "=== Build Docker images ==="
run_cmd docker compose build

echo
echo "=== Start internal app and proxy ==="
run_cmd docker compose up -d

echo
echo "=== Wait for the proxy to serve the app ==="
ready=0
for _ in $(seq 1 30); do
    if curl -fsS --connect-timeout 2 http://127.0.0.1:8080/ >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done

if [ "$ready" -ne 1 ]; then
    echo "ERROR: Proxy did not become ready"
    run_cmd docker compose logs
    exit 1
fi

run_cmd curl -sS -D - --connect-timeout 2 --max-time 8 http://127.0.0.1:8080/

echo
echo "=== Running containers ==="
run_cmd docker compose ps

echo
echo "=== Networks ==="
run_cmd docker network inspect task2_internal_private --format 'internal: {{.Name}} internal={{.Internal}} subnet={{(index .IPAM.Config 0).Subnet}}'
run_cmd docker network inspect task2_external_bridge --format 'external: {{.Name}} internal={{.Internal}} subnet={{(index .IPAM.Config 0).Subnet}}'

echo
echo "=== Test 1: HTTP to the internal app from outside should receive nothing ==="
echo
echo "+ docker run --rm --network task2_external_bridge curlimages/curl:8.14.1 --connect-timeout 5 --max-time 8 -sS http://172.30.0.2:8080"
set +e
docker run --rm --network task2_external_bridge curlimages/curl:8.14.1 \
    --connect-timeout 5 --max-time 8 -sS http://172.30.0.2:8080
direct_status=$?
set -e
echo "exit code: ${direct_status}"
if [ "$direct_status" -eq 0 ]; then
    echo "ERROR: Internal app responded to a request from outside the private network"
    exit 1
fi
echo "PASS: exit code ${direct_status}, no response from the internal app"

echo
echo "=== Test 2: HTTP to the proxy should return traffic from the app ==="
expected="Hello World! I'm Training App 2"

echo
echo "+ docker run --rm --network task2_external_bridge curlimages/curl:8.14.1 --connect-timeout 5 --max-time 8 -sS -D - http://172.31.0.10/"
proxy_raw="$(docker run --rm --network task2_external_bridge curlimages/curl:8.14.1 \
    --connect-timeout 5 --max-time 8 -sS -D - http://172.31.0.10/)"
proxy_status=$?
printf '%s\n' "$proxy_raw"
echo "exit code: ${proxy_status}"

echo
echo "+ curl -sS -D - --connect-timeout 5 --max-time 8 http://127.0.0.1:8080/"
host_raw="$(curl -sS -D - --connect-timeout 5 --max-time 8 http://127.0.0.1:8080/)"
host_status=$?
printf '%s\n' "$host_raw"
echo "exit code: ${host_status}"

proxy_body="$(printf '%s\n' "$proxy_raw" | tail -n 1)"
host_body="$(printf '%s\n' "$host_raw" | tail -n 1)"
if [ "$proxy_status" -eq 0 ] && [ "$host_status" -eq 0 ] \
    && [ "$proxy_body" = "$expected" ] && [ "$host_body" = "$expected" ]; then
    echo "PASS: both responses are: ${expected}"
else
    echo "ERROR: Proxy response did not match the app"
    echo "expected: ${expected}"
    echo "proxy body: ${proxy_body}"
    echo "host body: ${host_body}"
    exit 1
fi

echo
echo "=== Test complete ==="
echo "Log saved to: $LOG_FILE"
