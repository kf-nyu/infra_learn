#!/bin/bash

set -e

LOG_FILE="gateway_test_$(date +%Y%m%d_%H%M%S).log"

# Display output on screen and save it to the log file.
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Gateway Test ==="
echo "Date: $(date)"
echo "Log:  $LOG_FILE"

echo
echo "=== Clean up previous environment ==="
docker compose down

echo
echo "=== Build Docker images ==="
docker compose build

echo
echo "=== Create containers ==="
docker compose create

echo
echo "=== Start internal server only ==="
docker start internal_server

echo
echo "=== Running containers ==="
docker ps

echo
echo "=== Internal server routing table ==="
docker exec internal_server ip r

echo
echo "=== Test 1: Gateway OFF — ping should FAIL ==="
if docker exec internal_server ping -c 4 -W 2 1.1.1.1; then
    echo "ERROR: Internal server reached the Internet while gateway was OFF"
    exit 1
else
    echo "PASS: Internet unreachable while gateway was OFF"
fi

echo
echo "=== Start gateway server ==="
docker start gateway_server

echo
echo "=== Running containers ==="
docker ps

echo
echo "=== Internal server routing table ==="
docker exec internal_server ip r

echo
echo "=== Gateway server routing table ==="
docker exec gateway_server ip r

echo
echo "=== Gateway IP forwarding ==="
docker exec gateway_server sysctl net.ipv4.ip_forward
echo

echo
echo "=== Gateway Internet connectivity ==="
docker exec gateway_server curl -I --max-time 10 https://example.com
echo

echo "=== Gateway NAT rule before ping ==="
docker exec gateway_server iptables -t nat -L POSTROUTING -v -n
echo

echo "=== Test Internet ==="
docker exec gateway_server iptables -L FORWARD -v -n
docker exec gateway_server iptables -t nat -L POSTROUTING -v -n
echo
echo

echo "=== Test 2: Gateway ON — ping should SUCCEED ==="
# if docker exec internal_server ping -c 4 -W 2 1.1.1.1; then
if docker exec internal_server curl --connect-timeout 5 https://1.1.1.1 then
    echo "PASS: Internet reachable through gateway"
else
    echo "ERROR: Internet unreachable after gateway started"
    docker exec gateway_server iptables -L FORWARD -v -n
	docker exec gateway_server iptables -t nat -L POSTROUTING -v -n
	exit 1
fi

echo
echo "=== Gateway server NAT rule ==="
docker exec gateway_server iptables -t nat -L POSTROUTING -v -n
echo

echo "=== Test complete ==="
echo "Log saved to: $LOG_FILE"
