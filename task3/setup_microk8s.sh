#!/bin/bash

set -euo pipefail

if [ "$(uname -s)" != "Linux" ]; then
    echo "MicroK8s requires Linux. This machine is $(uname -s), which has no snap."
    echo "Push the task3 files and let the MicroK8s GitHub Actions workflow run the test."
    exit 1
fi

echo "=== Install MicroK8s ==="
if ! snap list microk8s >/dev/null 2>&1; then
    sudo snap install microk8s --classic --channel=latest/stable
fi

sudo microk8s status --wait-ready --timeout 300

# Docker on GitHub-hosted runners sets the FORWARD chain to DROP.
sudo iptables -P FORWARD ACCEPT

echo "=== Enable ingress ==="
sudo microk8s enable ingress

echo "=== Wait for the ingress controller ==="
for _ in $(seq 1 60); do
    if sudo microk8s kubectl get daemonset -n ingress -o name 2>/dev/null | grep -q .; then
        break
    fi
    sleep 5
done

ds="$(sudo microk8s kubectl get daemonset -n ingress -o jsonpath='{.items[0].metadata.name}')"
sudo microk8s kubectl -n ingress rollout status "daemonset/${ds}" --timeout=180s
sudo microk8s kubectl get pods -n ingress
echo "MicroK8s ingress is ready"
