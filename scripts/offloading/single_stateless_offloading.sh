#!/bin/bash

set -euo pipefail

# =====================================
# CARICAMENTO CONFIG ESPERIMENTO
# =====================================

source configs/exp_config.conf

if [ -z "$TEST" ] || [ -z "$NAMESPACE" ] || [ -z "$DEPLOYMENT" ]; then
    echo "Errore: configurazione esperimento incompleta"
    exit 1
fi

# =====================================
# CONFIGURAZIONE
# =====================================

export KUBECONFIG="$(pwd)/consumer-config"

OUTPUT_DIR="results/$TEST"
mkdir -p "$OUTPUT_DIR"
RESULT_FILE="$OUTPUT_DIR/offloading_time.txt"

echo "======================================"
echo "OFFLOADING TEST"
echo "======================================"
echo "Namespace: $NAMESPACE"
echo "Deployment: $DEPLOYMENT"
echo ""

# =====================================
# AVVIO MISURAZIONE
# =====================================

START_TS=$(date +%s)
START_TIME=$(date "+%Y-%m-%d %H:%M:%S")

echo "Avvio rischedulazione workload..."
echo "Start time: $START_TIME"

# =====================================
# RIAVVIO DEPLOYMENT
# =====================================

kubectl rollout restart deployment/"$DEPLOYMENT" \
-n "$NAMESPACE"

# =====================================
# ATTESA READY
# =====================================

echo ""
echo "Attendo che il deployment sia disponibile..."

kubectl rollout status deployment/"$DEPLOYMENT" \
-n "$NAMESPACE" --timeout=180s

# =====================================
# FINE MISURAZIONE
# =====================================

END_TS=$(date +%s)
END_TIME=$(date "+%Y-%m-%d %H:%M:%S")
ELAPSED=$((END_TS-START_TS))

# =====================================
# CONTROLLO PLACEMENT
# =====================================

NODE=$(kubectl get pods -n "$NAMESPACE" -l app="$DEPLOYMENT" \
  --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1:].spec.nodeName}')

echo "Pod schedulato su: $NODE"

NODE_TYPE=$(kubectl get node "$NODE" \
  -o jsonpath='{.metadata.labels.liqo\.io/type}')

if [ "$NODE_TYPE" != "virtual-node" ]; then
    echo "Errore: il pod non è sul virtual node (nodo: $NODE, type: ${NODE_TYPE:-n/a})"
    exit 1
fi

# =====================================
# SALVATAGGIO RISULTATO
# =====================================

cat > "$RESULT_FILE" <<EOF
Deployment=$DEPLOYMENT
Namespace=$NAMESPACE

Start_timestamp=$START_TS
End_timestamp=$END_TS

Start_time=$START_TIME
End_time=$END_TIME

Offloading_time_seconds=$ELAPSED
EOF

echo ""
echo "======================================"
echo "OFFLOADING COMPLETATO"
echo "======================================"

echo ""
echo "Tempo di convergenza: ${ELAPSED} secondi"
echo "Risultato salvato: $RESULT_FILE"

sleep 10

echo ""
echo "Esecuzione snapshot offloading..."

./scripts/offloading/snapshot_offloading.sh