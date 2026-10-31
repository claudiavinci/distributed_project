#!/bin/bash

# Misura dell'offloading "a freddo" di un gruppo di servizi stateless.
#
# Prerequisiti:
#   - peering gia' attivo (nodo virtuale presente)
#   - namespace NON offloadato (oppure lancia con AUTO_RESET=1)
#   - MANIFEST con nodeSelector liqo.io/type=virtual-node sui servizi da spostare
#
# Uso:
#   ./offloading_multi_stateless.sh
#   AUTO_RESET=1 ./offloading_multi_stateless.sh   # fa prima l'unoffload

set -euo pipefail

# =====================================
# CONFIG ESPERIMENTO
# =====================================

source configs/exp_config.conf

for v in TEST NAMESPACE MANIFEST; do
    if [ -z "${!v:-}" ]; then
        echo "Errore: variabile mancante in exp_config.conf: $v"
        exit 1
    fi
done

if [ -z "${DEPLOYMENTS_LIST[*]:-}" ]; then
    echo "Errore: DEPLOYMENTS_LIST mancante in exp_config.conf"
    exit 1
fi

if [ ! -f "$MANIFEST" ]; then
    echo "Errore: manifest non trovato: $MANIFEST"
    exit 1
fi

# DEPLOYMENTS_LIST puo' essere una stringa o un array bash
read -r -a DEPLOY_LIST <<< "${DEPLOYMENTS_LIST[*]}"

FRONTEND_DEPLOYMENT="${FRONTEND_DEPLOYMENT:-frontend}"
AUTO_RESET="${AUTO_RESET:-1}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"

export KUBECONFIG="$(pwd)/consumer-config"

OUTPUT_DIR="results/$TEST"
RESULT_FILE="$OUTPUT_DIR/offloading_time.txt"
mkdir -p "$OUTPUT_DIR"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "======================================"
echo "OFFLOADING A FREDDO (multi stateless)"
echo "======================================"
echo "Namespace:   $NAMESPACE"
echo "Manifest:    $MANIFEST"
echo "Deployments: ${DEPLOY_LIST[*]}"
echo ""

# =====================================
# PRECONDIZIONI
# =====================================

if [ "$(kubectl get nodes -l liqo.io/type=virtual-node -o name | wc -l)" -lt 1 ]; then
    echo "Errore: nessun nodo virtuale trovato, il peering non e' attivo"
    exit 1
fi

if [ -n "$(kubectl get namespaceoffloading -n "$NAMESPACE" -o name 2>/dev/null)" ]; then
    if [ "$AUTO_RESET" = "1" ]; then
        echo "Namespace gia' offloadato: eseguo unoffload..."
        liqoctl unoffload namespace "$NAMESPACE"
        sleep 10
    else
        echo "Errore: il namespace $NAMESPACE e' gia' offloadato."
        echo "Esegui 'liqoctl unoffload namespace $NAMESPACE' oppure lancia con AUTO_RESET=1"
        exit 1
    fi
fi

# =====================================
# STATO INIZIALE (non misurato)
# =====================================
kubectl get pods -n shop --no-headers \
  | awk '$3=="OffloadingAborted"{print $1}' \
  | xargs -r kubectl delete pod -n "$NAMESPACE"
echo "Applico il manifest..."
kubectl apply -f "$MANIFEST" -n "$NAMESPACE"
sleep 10

echo ""
echo "Stato iniziale dei pod del gruppo:"
for d in "${DEPLOY_LIST[@]}"; do
    kubectl get pods -n "$NAMESPACE" -l app="$d" --no-headers || true
done

# =====================================
# MISURAZIONE
# =====================================

START_TS=$(date +%s)
START_TIME=$(date "+%Y-%m-%d %H:%M:%S")

echo ""
echo "Start time: $START_TIME"
echo "Offloading del namespace..."

liqoctl offload namespace "$NAMESPACE" \
    --namespace-mapping-strategy EnforceSameName \
    --pod-offloading-strategy LocalAndRemote

kubectl wait --for=jsonpath='{.status.offloadingPhase}'=Ready \
    namespaceoffloading/offloading -n "$NAMESPACE" --timeout=120s \
    || echo "Nota: offloadingPhase non Ready entro 120s, proseguo"

OFFLOAD_CMD_TS=$(date +%s)

# i pod creati prima dell'offload non hanno la toleration: vanno ricreati
for d in "${DEPLOY_LIST[@]}"; do
    kubectl rollout restart deployment/"$d" -n "$NAMESPACE"
done

echo ""
echo "Attendo che i deployment siano disponibili..."

PIDS=()
for d in "${DEPLOY_LIST[@]}"; do
    (
        kubectl rollout status deployment/"$d" -n "$NAMESPACE" \
            --timeout="$ROLLOUT_TIMEOUT" > /dev/null \
        && date +%s > "$TMP_DIR/$d.end"
    ) &
    PIDS+=($!)
done

FAILED=0
for pid in "${PIDS[@]}"; do
    wait "$pid" || FAILED=1
done

if [ "$FAILED" -ne 0 ]; then
    echo "Errore: almeno un deployment non e' diventato disponibile entro $ROLLOUT_TIMEOUT"
    exit 1
fi

# fine misura = istante in cui l'ultimo deployment e' pronto
END_TS="$START_TS"
for d in "${DEPLOY_LIST[@]}"; do
    E=$(cat "$TMP_DIR/$d.end")
    if [ "$E" -gt "$END_TS" ]; then
        END_TS="$E"
    fi
done

END_TIME=$(date -d "@$END_TS" "+%Y-%m-%d %H:%M:%S")
ELAPSED=$((END_TS - START_TS))
OFFLOAD_CMD_SECONDS=$((OFFLOAD_CMD_TS - START_TS))

# =====================================
# PLACEMENT (informativo, non blocca)
# =====================================

PLACEMENT_LINES=""

for d in "${DEPLOY_LIST[@]}"; do
    NODE=$(kubectl get pods -n "$NAMESPACE" -l app="$d" \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1:].spec.nodeName}') || NODE=""

    NODE_TYPE=""
    if [ -n "$NODE" ]; then
        NODE_TYPE=$(kubectl get node "$NODE" \
            -o jsonpath='{.metadata.labels.liqo\.io/type}') || NODE_TYPE=""
    fi

    echo "$d schedulato su: ${NODE:-n/a} (${NODE_TYPE:-n/a})"
    PLACEMENT_LINES+="Placement_${d}=${NODE:-n/a}:${NODE_TYPE:-n/a}"$'\n'
done

# =====================================
# SALVATAGGIO RISULTATO
# =====================================

{
    echo "Manifest=$MANIFEST"
    echo "Deployments=${DEPLOY_LIST[*]}"
    echo "Namespace=$NAMESPACE"
    echo ""
    echo "Start_timestamp=$START_TS"
    echo "End_timestamp=$END_TS"
    echo ""
    echo "Start_time=$START_TIME"
    echo "End_time=$END_TIME"
    echo ""
    # da prima di 'liqoctl offload' all'ultimo deployment pronto
    echo "Offloading_time_seconds=$ELAPSED"
    # solo il comando di offload del namespace
    echo "Offload_command_seconds=$OFFLOAD_CMD_SECONDS"
    echo ""
    for d in "${DEPLOY_LIST[@]}"; do
        echo "Offloading_time_${d}_seconds=$(( $(cat "$TMP_DIR/$d.end") - START_TS ))"
    done
    echo ""
    printf "%s" "$PLACEMENT_LINES"
} > "$RESULT_FILE"

echo ""
echo "======================================"
echo "OFFLOADING COMPLETATO"
echo "======================================"
echo "Tempo di convergenza (gruppo): ${ELAPSED} s (comando di offload: ${OFFLOAD_CMD_SECONDS} s)"
echo "Risultato salvato: $RESULT_FILE"

# =====================================
# RIAVVIO FRONTEND (dopo la misura)
# =====================================

echo ""
echo "Riavvio $FRONTEND_DEPLOYMENT per aggiornare le connessioni..."

kubectl rollout restart deployment/"$FRONTEND_DEPLOYMENT" -n "$NAMESPACE"
kubectl rollout status deployment/"$FRONTEND_DEPLOYMENT" -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"

sleep 10

echo ""
echo "Esecuzione snapshot offloading..."

./scripts/offloading/snapshot_offloading.sh