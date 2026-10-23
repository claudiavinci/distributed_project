#!/bin/bash

set -e

# =========================
# CARICAMENTO CONFIG
# =========================

source configs/liqo_config.conf

if [ -z "$REMOTE_KUBECONFIG" ] || \
   [ -z "$KUBECONFIG" ] || \
   [ -z "$REMOTE_NODE" ] || \
   [ -z "$NAMESPACE" ] || \
   [ -z "$OFFLOADING_NAME" ]; then

    echo "Errore: configurazione liqo incompleta"
    exit 1
fi

# =====================================
# CONFIGURAZIONE
# =====================================

export KUBECONFIG="$KUBECONFIG"

echo "======================================"
echo "PREPARAZIONE AMBIENTE LIQO"
echo "======================================"

# =====================================
# CONTROLLO PEERING
# =====================================

echo ""
echo "Controllo peering..."

if liqoctl info | grep -q "$REMOTE_NODE"; then
    echo "Peering già presente."
else
    echo "Peering assente."
    echo "Avvio peering..."

    liqoctl peer \
    --kubeconfig="$KUBECONFIG" \
    --remote-kubeconfig "$REMOTE_KUBECONFIG" \
    --gw-server-service-type NodePort
fi

# =====================================
# ATTESA VIRTUAL NODE
# =====================================

echo ""
echo "Attendo VirtualNode..."

TIMEOUT=300
START=$(date +%s)

while ! kubectl get nodes | grep -q "$REMOTE_NODE"
do

    NOW=$(date +%s)
    ELAPSED=$((NOW-START))

    if [ "$ELAPSED" -gt "$TIMEOUT" ]; then
        echo "Timeout creazione VirtualNode"
        exit 1
    fi
    sleep 5
done

echo "VirtualNode disponibile."

# =====================================
# CONFIGURAZIONE OFFLOADING
# =====================================

echo ""
echo "Controllo policy offloading..."

POLICY=$(kubectl get namespaceoffloading \
"$OFFLOADING_NAME" \
-n "$NAMESPACE" \
-o jsonpath='{.spec.podOffloadingStrategy}')

if [ "$POLICY" != "LocalAndRemote" ]; then

    echo "Policy attuale: $POLICY"
    echo "Imposto LocalAndRemote..."

    kubectl patch namespaceoffloading \
    "$OFFLOADING_NAME" \
    -n "$NAMESPACE" \
    --type=merge \
    -p '
    {
      "spec":{
        "podOffloadingStrategy":"LocalAndRemote"
      }
    }'
else
    echo "Policy già corretta."
fi

echo ""
echo "======================================"
echo "AMBIENTE LIQO PRONTO"
echo "======================================"

kubectl get nodes
kubectl get namespaceoffloading \
-n "$NAMESPACE"