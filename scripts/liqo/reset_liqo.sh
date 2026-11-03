#!/bin/bash
# reset_liqo.sh

set -uo pipefail

source configs/liqo_config.conf

if [ -z "${REMOTE_KUBECONFIG:-}" ] || \
   [ -z "${KUBECONFIG:-}" ] || \
   [ -z "${REMOTE_NODE:-}" ] || \
   [ -z "${NAMESPACE:-}" ]; then
    echo "Errore: configurazione Liqo incompleta"
    exit 1
fi
OFFLOADING_NAME="${OFFLOADING_NAME:-offloading}"

export KUBECONFIG="$KUBECONFIG"

# =====================================
# FUNZIONI
# =====================================

do_unpeer() {
    liqoctl unpeer \
        --remote-kubeconfig "$REMOTE_KUBECONFIG"
}

force_terminating_pods() {
    local pods

    pods=$(kubectl get pods -n "$NAMESPACE" \
        --field-selector=status.phase!=Succeeded \
        -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}') || return 1

    if [ -z "$pods" ]; then
        echo "Nessun pod Terminating."
        return 0
    fi

    while IFS= read -r pod; do
        [ -z "$pod" ] && continue

        echo "Forzo eliminazione: $pod"

        kubectl patch pod "$pod" -n "$NAMESPACE" \
            --type=merge \
            -p '{"metadata":{"finalizers":null}}' || true

        kubectl delete pod "$pod" -n "$NAMESPACE" \
            --force --grace-period=0 || true

    done <<< "$pods"
}

check_state() {
    echo ""
    echo "Stato risorse Liqo:"
    kubectl get foreignclusters -A || true
    kubectl get namespaceoffloadings -A || true
    kubectl get namespacemaps -A || true
}

# =====================================
# RESET LIQO
# =====================================

echo "======================================"
echo "RESET LIQO"
echo "======================================"

echo ""
echo "[1] Unpeer..."

if do_unpeer; then
    echo "Unpeer completato correttamente."
else
    echo "Unpeer fallito o in timeout."
    echo ""
    echo "[1.2] Eliminazione pod Terminating..."
    force_terminating_pods || {
        echo "Errore nel recupero dei pod."
        exit 1
    }

    sleep 5

    echo ""
    echo "[1.3] Riprovo Unpeer..."

    if do_unpeer; then
        echo "Secondo Unpeer completato."
    else
        echo "Secondo Unpeer fallito o in timeout."
        echo "Verifico lo stato prima di procedere."
    fi
fi

# =====================================
# VERIFICA RIMOZIONE
# =====================================

echo ""
echo "[2] Attendo rimozione VirtualNode..."

TIMEOUT=120
START=$(date +%s)

while kubectl get node "$REMOTE_NODE" \
    >/dev/null 2>&1; do

    NOW=$(date +%s)

    if [ $((NOW - START)) -ge "$TIMEOUT" ]; then
        echo "Timeout rimozione VirtualNode."
        check_state
        exit 1
    fi
    sleep 5
done
echo "VirtualNode rimosso."

# =====================================
# NUOVO PEERING
# =====================================

echo ""
echo "[3] Nuovo Peering..."

if ! liqoctl peer \
    --kubeconfig="$KUBECONFIG" \
    --remote-kubeconfig "$REMOTE_KUBECONFIG" \
    --gw-server-service-type NodePort; then

    echo "Errore durante il nuovo peering."
    check_state
    exit 1
fi

# =====================================
# ATTESA VIRTUAL NODE
# =====================================

echo ""
echo "[4] Attendo VirtualNode..."

TIMEOUT=300
START=$(date +%s)

while ! kubectl get node "$REMOTE_NODE" \
    >/dev/null 2>&1; do

    NOW=$(date +%s)
    if [ $((NOW - START)) -ge "$TIMEOUT" ]; then
        echo "Timeout creazione VirtualNode."
        check_state
        exit 1
    fi
    sleep 5
done

echo "VirtualNode disponibile."

echo ""
echo "[5] Controllo NamespaceOffloading..."

if kubectl get namespaceoffloading "$OFFLOADING_NAME" \
    -n "$NAMESPACE" >/dev/null 2>&1; then

    POLICY=$(kubectl get namespaceoffloading "$OFFLOADING_NAME" \
        -n "$NAMESPACE" \
        -o jsonpath='{.spec.podOffloadingStrategy}')

    echo "Policy attuale: $POLICY"
else
    echo "NamespaceOffloading assente."
    echo "Sarà necessario configurare nuovamente l'offloading."
fi

# =====================================
# STATO FINALE
# =====================================

echo ""
echo "======================================"
echo "RESET LIQO COMPLETATO"
echo "======================================"

kubectl get nodes
check_state
kubectl get pods -n "$NAMESPACE" -o wide


