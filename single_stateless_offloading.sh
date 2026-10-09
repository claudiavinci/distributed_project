#!/bin/bash

set -e

# =====================================
# CONFIGURAZIONE
# =====================================

export KUBECONFIG="$(pwd)/consumer-config"

NAMESPACE="shop"
DEPLOYMENT="productcatalogservice"

OUTPUT_DIR="experiments/offloading_stateless/single_stateless"

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

kubectl rollout restart deployment/$DEPLOYMENT \
-n $NAMESPACE

# =====================================
# ATTESA READY
# =====================================

echo ""
echo "Attendo che il deployment sia disponibile..."

kubectl rollout status deployment/$DEPLOYMENT \
-n $NAMESPACE

# =====================================
# FINE MISURAZIONE
# =====================================

END_TS=$(date +%s)

END_TIME=$(date "+%Y-%m-%d %H:%M:%S")

ELAPSED=$((END_TS-START_TS))

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
echo "Tempo di convergenza:"
echo "${ELAPSED} secondi"

echo ""
echo "Risultato salvato:"
echo "$RESULT_FILE"

echo ""
echo "Eseguire ora:"
echo "./snapshot_offloading.sh"