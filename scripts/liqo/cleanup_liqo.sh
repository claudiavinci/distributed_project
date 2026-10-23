#!/bin/bash
# cleanup_liqo.sh
set -uo pipefail

source configs/liqo_config.conf

if [ -z "${REMOTE_KUBECONFIG:-}" ] || [ -z "${KUBECONFIG:-}" ] || [ -z "${REMOTE_NODE:-}" ] || \
   [ -z "${NAMESPACE:-}" ] || [ -z "${OFFLOADING_NAME:-}" ]; then
    echo "Errore: configurazione liqo incompleta"
    exit 1
fi

export KUBECONFIG="$KUBECONFIG"

force_terminating_pods() {
    for pod in $(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
                 | awk '$3=="Terminating"{print $1}'); do
        echo "  forzo $pod"
        kubectl patch pod "$pod" -n "$NAMESPACE" --type=merge \
            -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
        kubectl delete pod "$pod" -n "$NAMESPACE" --force --grace-period=0 \
            2>/dev/null || true
    done
}

do_unpeer() {
    liqoctl unpeer --remote-kubeconfig "$REMOTE_KUBECONFIG"
}

echo "======================================"
echo "CLEANUP LIQO"
echo "======================================"

echo "[1] Unoffload namespace $NAMESPACE..."
if liqoctl unoffload namespace "$NAMESPACE" --skip-confirm; then
    echo "Unoffload ok."
    echo "[2] Unpeer..."
    if ! do_unpeer; then
        echo "Unpeer FALLITO."
        echo "Controlla con: liqoctl status / kubectl get foreignclusters"
        exit 1
    fi
else
    echo "Unoffload FALLITO: recupero."
    sleep 5
    echo "[2] Elimino i pod Terminating..."
    force_terminating_pods

    echo "[3] Riprovo unoffload namespace $NAMESPACE..."
    sleep 5
    if ! liqoctl unoffload namespace "$NAMESPACE" --skip-confirm; then
        echo "Secondo unoffload FALLITO."
        echo "Controlla con: kubectl get namespaceoffloadings,namespacemaps -A"
        exit 1
    fi
    echo "Unoffload ok."

    echo "[4] Unpeer..."
    if ! do_unpeer; then
        # Se l'unpeer fallisce, il vecchio peering è ancora lì in stato
        # incoerente: rifare il peer sopra creerebbe un doppione.
        echo "Unpeer FALLITO."
        echo "Controlla con: liqoctl status / kubectl get foreignclusters"
        exit 1
    fi
    sleep 20
fi

echo ""
echo "Stato finale:"
kubectl get nodes
kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || true
kubectl get foreignclusters 2>/dev/null || true
echo "Cleanup completato."