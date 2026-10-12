#!/bin/bash

set -e

# =========================
# CARICAMENTO CONFIG
# =========================

source configs/liqo_config.conf

if [ -z "$REMOTE_KUBECONFIG" ] || \
   [ -z "$REMOTE_NODE" ] || \
   [ -z "$NAMESPACE" ] || \
   [ -z "$OFFLOADING_NAME" ]; then

    echo "Errore: configurazione liqo incompleta"
    exit 1
fi

# =====================================
# CONFIGURAZIONE
# =====================================

export KUBECONFIG="$(pwd)/consumer-config"

echo "======================================"
echo "CLEANUP LIQO"
echo "======================================"

# =====================================
# BLOCCA NUOVI OFFLOAD
# =====================================

# echo ""
# echo "Imposto policy Local..."

# kubectl patch namespaceoffloading \
# "$OFFLOADING_NAME" \
# -n "$NAMESPACE" \
# --type=merge \
# -p '
# {
#  "spec":{
#    "podOffloadingStrategy":"Local"
#  }
# }'

# # =====================================
# # ATTENDO RITORNO POD
# # =====================================

# echo ""
# echo "Attendo ritorno workload locale..."

# TIMEOUT=300
# START=$(date +%s)

# while kubectl get pods \
# -n "$NAMESPACE" \
# -o wide | grep -q "$REMOTE_NODE"
# do
#     echo "Pod ancora sul VirtualNode:"
#     kubectl get pods \
#     -n "$NAMESPACE" \
#     -o wide | grep "$REMOTE_NODE"

#     NOW=$(date +%s)
#     ELAPSED=$((NOW-START))

#     if [ "$ELAPSED" -gt "$TIMEOUT" ]; then
#         echo "Timeout"
#         exit 1
#     fi

#     sleep 10
# done

# echo "Tutti i pod sono locali."

# =====================================
# UNPEER
# =====================================

if liqoctl info | grep -q "$REMOTE_NODE"; then
    echo "Rimuovo peering..."
    liqoctl unpeer \
    --remote-kubeconfig "$REMOTE_KUBECONFIG" || true
else
    echo "Nessun peering presente."
fi
sleep 20

echo ""
echo "Stato finale:"

kubectl get nodes

kubectl get virtualnodes -A || true

echo ""
echo "Cleanup completato."