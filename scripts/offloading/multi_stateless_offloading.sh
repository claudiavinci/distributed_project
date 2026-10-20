#!/bin/bash

set -euo pipefail

# =====================================
# CARICAMENTO CONFIG ESPERIMENTO
# =====================================

source configs/exp_config.conf

for v in TEST NAMESPACE; do
    if [ -z "${!v:-}" ]; then
        echo "Errore: variabile mancante in exp_config.conf: $v"
        exit 1
    fi
done

if [ -z "${DEPLOYMENTS_LIST[*]:-}" ]; then
    echo "Errore: DEPLOYMENTS_LIST mancante in exp_config.conf"
    exit 1
fi

# stringa o array bash
read -r -a DEPLOY_LIST <<< "${DEPLOYMENTS_LIST[*]}"

# =====================================
# CONFIGURAZIONE
# =====================================

export KUBECONFIG="$(pwd)/consumer-config"

OUTPUT_DIR="results/$TEST"
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/offloading_time.txt"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "======================================"
echo "OFFLOADING TEST (multi stateless)"
echo "======================================"
echo "Namespace: $NAMESPACE"
echo "Deployments: ${DEPLOY_LIST[*]}"
echo ""

# =====================================
# AVVIO MISURAZIONE
# =====================================

START_TS=$(date +%s)
START_TIME=$(date "+%Y-%m-%d %H:%M:%S")

echo "Avvio rischedulazione workload..."
echo "Start time: $START_TIME"

# =====================================
# RIAVVIO DEPLOYMENT (tutti insieme)
# =====================================

for d in "${DEPLOY_LIST[@]}"; do
    kubectl rollout restart deployment/"$d" -n "$NAMESPACE"
done

# =====================================
# ATTESA READY (in parallelo, un tempo per deployment)
# =====================================

echo ""
echo "Attendo che i deployment siano disponibili..."

PIDS=()
for d in "${DEPLOY_LIST[@]}"; do
    (
        kubectl rollout status deployment/"$d" -n "$NAMESPACE" \
            --timeout=180s > /dev/null \
        && date +%s > "$TMP_DIR/$d.end"
    ) &
    PIDS+=($!)
done

FAILED=0
for pid in "${PIDS[@]}"; do
    wait "$pid" || FAILED=1
done

if [ "$FAILED" -ne 0 ]; then
    echo "Errore: almeno un deployment non e' diventato disponibile entro 180s"
    exit 1
fi

# =====================================
# FINE MISURAZIONE (istante dell'ultimo deployment pronto)
# =====================================

END_TS="$START_TS"
for d in "${DEPLOY_LIST[@]}"; do
    E=$(cat "$TMP_DIR/$d.end")
    if [ "$E" -gt "$END_TS" ]; then
        END_TS="$E"
    fi
done

END_TIME=$(date -d "@$END_TS" "+%Y-%m-%d %H:%M:%S")
ELAPSED=$((END_TS-START_TS))

# =====================================
# CONTROLLO PLACEMENT (tutti sul virtual node)
# =====================================

PLACEMENT_LINES=""
PLACEMENT_OK=1

for d in "${DEPLOY_LIST[@]}"; do
    NODE=$(kubectl get pods -n "$NAMESPACE" -l app="$d" \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1:].spec.nodeName}') || NODE=""

    NODE_TYPE=""
    if [ -n "$NODE" ]; then
        NODE_TYPE=$(kubectl get node "$NODE" \
          -o jsonpath='{.metadata.labels.liqo\.io/type}') || NODE_TYPE=""
    fi

    echo "$d schedulato su: ${NODE:-n/a}"

    if [ "$NODE_TYPE" != "virtual-node" ]; then
        echo "NOTA: $d non e' sul virtual node (nodo: ${NODE:-n/a}, type: ${NODE_TYPE:-n/a})"
        PLACEMENT_OK=0
    fi

    PLACEMENT_LINES+="Placement_${d}=${NODE:-n/a}"$'\n'
done

# =====================================
# SALVATAGGIO RISULTATO
# =====================================

{
    echo "Deployments=${DEPLOY_LIST[*]}"
    echo "Namespace=$NAMESPACE"
    echo ""
    echo "Start_timestamp=$START_TS"
    echo "End_timestamp=$END_TS"
    echo ""
    echo "Start_time=$START_TIME"
    echo "End_time=$END_TIME"
    echo ""
    # tempo del gruppo (ultimo pronto): compatibile con il formato precedente
    echo "Offloading_time_seconds=$ELAPSED"
    echo ""
    for d in "${DEPLOY_LIST[@]}"; do
        echo "Offloading_time_${d}_seconds=$(( $(cat "$TMP_DIR/$d.end") - START_TS ))"
    done
    echo ""
    echo "All_on_virtual_nodes=$PLACEMENT_OK"
    printf "%s" "$PLACEMENT_LINES"
} > "$RESULT_FILE"

echo ""
echo "======================================"
echo "OFFLOADING COMPLETATO"
echo "======================================"

echo ""
echo "Tempo di convergenza (gruppo): ${ELAPSED} secondi"
echo "Risultato salvato: $RESULT_FILE"

# =====================================
# RIAVVIO FRONTEND (aggiorna le connessioni verso i nuovi pod)
# =====================================

FRONTEND_DEPLOYMENT="${FRONTEND_DEPLOYMENT:-frontend}"

echo ""
echo "Riavvio $FRONTEND_DEPLOYMENT per aggiornare le connessioni..."

kubectl rollout restart deployment/"$FRONTEND_DEPLOYMENT" -n "$NAMESPACE"
kubectl rollout status deployment/"$FRONTEND_DEPLOYMENT" -n "$NAMESPACE" --timeout=180s

sleep 10

echo ""
echo "Esecuzione snapshot offloading..."

./scripts/offloading/snapshot_offloading.sh