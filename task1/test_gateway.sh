#!/bin/bash

set -e

cd "$(dirname "$0")"

LOG_FILE="gateway_test_$(date +%Y%m%d_%H%M%S).log"

# Display output on screen and save it to the log file.
exec > >(tee -a "$LOG_FILE") 2>&1

# Print the command, run it, and leave its output in the log.
run_cmd() {
    echo
    echo "+ $*"
    "$@"
}

echo "=== Gateway Test ==="
echo "Date: $(date)"
echo "Log:  $LOG_FILE"

echo
echo "=== Clean up previous environment ==="
run_cmd docker compose down

echo
echo "=== Build Docker images ==="
run_cmd docker compose build

echo
echo "=== Create containers ==="
run_cmd docker compose create

echo
echo "=== Start internal server only ==="
run_cmd docker start internal_server

echo
echo "=== Running containers ==="
run_cmd docker ps

echo
echo "=== Internal server routing table ==="
run_cmd docker exec internal_server ip r

echo
echo "=== Test 1: Gateway OFF — curl should FAIL ==="
echo
echo "+ docker exec internal_server curl --connect-timeout 5 https://1.1.1.1"
set +e
docker exec internal_server curl --connect-timeout 5 https://1.1.1.1
off_status=$?
set -e
echo "exit code: ${off_status}"
if [ "$off_status" -eq 0 ]; then
    echo "ERROR: Internal server reached the Internet while gateway was OFF"
    exit 1
fi
echo "PASS: exit code ${off_status}, Internet unreachable while gateway was OFF"

echo
echo "=== Start gateway server ==="
run_cmd docker start gateway_server

echo
echo "=== Running containers ==="
run_cmd docker ps

echo
echo "=== Internal server routing table ==="
run_cmd docker exec internal_server ip r

echo
echo "=== Gateway server routing table ==="
run_cmd docker exec gateway_server ip r

echo
echo "=== Gateway IP forwarding ==="
run_cmd docker exec gateway_server sysctl net.ipv4.ip_forward

echo
echo "=== Gateway NAT rule before curl ==="
run_cmd docker exec gateway_server iptables -t nat -L POSTROUTING -v -n

echo
echo "=== Test 2: Gateway ON — curl should SUCCEED ==="
echo
echo "+ docker exec internal_server curl --connect-timeout 5 https://1.1.1.1"
set +e
docker exec internal_server curl --connect-timeout 5 https://1.1.1.1
on_status=$?
set -e
echo "exit code: ${on_status}"
if [ "$on_status" -ne 0 ]; then
    echo "ERROR: Internet unreachable after gateway started"
    exit 1
fi
echo "PASS: exit code ${on_status}, Internet reachable through gateway"

echo
echo "=== Gateway server NAT rule ==="
run_cmd docker exec gateway_server iptables -t nat -L POSTROUTING -v -n

echo
echo "=== Test complete ==="
echo "Log saved to: $LOG_FILE"
