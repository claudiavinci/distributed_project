#!/bin/bash

set -e

# =========================
# CONFIGURAZIONE
# =========================

NAMESPACE="monitoring"
SERVICE="monitoring-grafana"
LOCAL_PORT="3000"
REMOTE_PORT="80"

export KUBECONFIG="$(pwd)/consumer-config"

# =========================
# PORT-FORWARD GRAFANA
# =========================

echo "================================="
echo "Avvio Grafana port-forward"
echo "================================="

echo ""
echo "Namespace: $NAMESPACE"
echo "Service: $SERVICE"
echo "URL: http://localhost:${LOCAL_PORT}"
echo ""

kubectl port-forward \
-n "$NAMESPACE" \
svc/"$SERVICE" \
${LOCAL_PORT}:${REMOTE_PORT}