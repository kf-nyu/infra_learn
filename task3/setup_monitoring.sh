#!/bin/bash

set -euo pipefail

if [ "$(uname -s)" != "Linux" ]; then
    echo "MicroK8s requires Linux. This machine is $(uname -s), which has no snap."
    echo "Run this on the Ubuntu PC after ./setup_microk8s.sh."
    exit 1
fi

if ! sudo microk8s status --wait-ready --timeout 60 >/dev/null; then
    echo "ERROR: microk8s is not ready. Run ./setup_microk8s.sh first."
    exit 1
fi

echo "=== Enable observability ==="
if sudo microk8s kubectl get deploy -n observability kube-prom-stack-grafana >/dev/null 2>&1; then
    echo "Observability is already installed"
else
    # Also enables dns, helm3, and hostpath-storage. Installs Prometheus,
    # Grafana, Alertmanager, and Loki in the observability namespace.
    sudo microk8s enable observability --without-tempo
fi

echo "=== Wait for Grafana ==="
sudo microk8s kubectl -n observability rollout status deployment/kube-prom-stack-grafana --timeout=600s

echo "=== Wait for Prometheus ==="
found=0
for _ in $(seq 1 60); do
    if sudo microk8s kubectl -n observability get pods -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -q .; then
        found=1
        break
    fi
    sleep 10
done
if [ "$found" -ne 1 ]; then
    echo "ERROR: Prometheus pod did not appear"
    sudo microk8s kubectl get pods -n observability
    exit 1
fi
sudo microk8s kubectl -n observability wait pod -l app.kubernetes.io/name=prometheus --for=condition=Ready --timeout=600s

sudo microk8s kubectl get pods -n observability

password="$(sudo microk8s kubectl -n observability get secret kube-prom-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)"

echo
echo "Grafana user: admin"
echo "Grafana password: ${password}"
echo
echo "In another session, leave this port-forward running:"
echo "  sudo microk8s kubectl -n observability port-forward --address 127.0.0.1 svc/kube-prom-stack-grafana 3000:80"
echo
echo "Then open http://127.0.0.1:3000"
