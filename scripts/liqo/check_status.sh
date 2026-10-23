#!/bin/bash
# check_liqo.sh - verifica lo stato di Liqo e ripara solo se serve
# Uso: ./check_liqo.sh            (controlla e ripara)
#      ./check_liqo.sh --check    (solo controllo, niente riparazione)
set -uo pipefail

source configs/liqo_config.conf

if [ -z "${REMOTE_KUBECONFIG:-}" ] || [ -z "${KUBECONFIG:-}" ] || \
   [ -z "${REMOTE_NODE:-}" ] || [ -z "${NAMESPACE:-}" ] || \
   [ -z "${OFFLOADING_NAME:-}" ]; then
    echo "Errore: configurazione liqo incompleta"
    exit 1
fi

export KUBECONFIG="$KUBECONFIG"

# --- CONTROLLI (ognuno stampa il problema e ritorna 1 se rotto) --------

provider_ok() {
    local n
    n=$(kubectl --kubeconfig "$REMOTE_KUBECONFIG" get nodes --no-headers \
        --request-timeout=10s 2>/dev/null | grep -vc " Ready ")
    # se get nodes fallisce, n vale 0: controllo esplicitamente la raggiungibilità
    kubectl --kubeconfig "$REMOTE_KUBECONFIG" get nodes \
        --request-timeout=10s >/dev/null 2>&1 || { echo "  provider irraggiungibile"; return 1; }
    [ "$n" -eq 0 ] || { echo "  provider con nodi NotReady"; return 1; }
}

node_ready() {
    [ "$(kubectl get node "$REMOTE_NODE" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null)" = "True" ] || { echo "  nodo $REMOTE_NODE assente o NotReady"; return 1; }
}

offloading_ready() {
    [ "$(kubectl get namespaceoffloading "$OFFLOADING_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.offloadingPhase}' 2>/dev/null)" = "Ready" ] \
        || { echo "  offloading assente o non Ready"; return 1; }
}

no_stuck_pods() {
    # un Terminating è normale per qualche secondo: ricontrollo dopo una pausa
    if kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q Terminating; then
        sleep 30
        if kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q Terminating; then
            echo "  pod bloccati in Terminating"
            return 1
        fi
    fi
}

is_healthy() {
    local rc=0
    node_ready        || rc=1
    offloading_ready  || rc=1
    no_stuck_pods     || rc=1
    return $rc
}

# --- LOGICA ------------------------------------------------------------

echo "======================================"
echo "CHECK LIQO"
echo "======================================"

# Se il provider è giù, cleanup e setup non possono aiutare: fermati subito
echo "Provider..."
if ! provider_ok; then
    echo "Il provider non è utilizzabile: ripristina prima i container kind del provider."
    exit 2
fi

echo "Liqo..."
if is_healthy; then
    echo "Tutto ok: peering e offloading funzionanti."
    exit 0
fi
