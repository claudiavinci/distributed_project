#!/bin/bash

set -euo pipefail

# =========================
# CARICAMENTO CONFIG
# =========================

source configs/exp_config.conf

REQUIRED_VARS=(
  TEST THREADS CONNECTIONS DURATION RUNS COOLDOWN
  NAMESPACE MONITORING_NAMESPACE WRK_POD TARGET_URL WRK_TIMEOUT
)

for v in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!v:-}" ]; then
        echo "Errore: variabile mancante in exp_config.conf: $v"
        exit 1
    fi
done

# =========================
# CONFIGURAZIONE
# =========================

export KUBECONFIG="$(pwd)/consumer-config"

GRAFANA_PID=""

OUTPUT_DIR="$(pwd)/results/${TEST}/capacity_test/c${CONNECTIONS}/raw"

mkdir -p "$OUTPUT_DIR"

# =========================
# CLEANUP
# =========================

cleanup() {

    echo ""
    echo "================================="
    echo "Pulizia risorse..."
    echo "================================="

    if [ -n "$GRAFANA_PID" ]; then
        echo "Chiusura port-forward Grafana..."
        kill "$GRAFANA_PID" 2>/dev/null || true
        wait "$GRAFANA_PID" 2>/dev/null || true
    fi

    kubectl delete pod \
        "$WRK_POD" \
        -n "$NAMESPACE" \
        --ignore-not-found || true

    echo "Pulizia completata."
}

trap cleanup EXIT
trap 'exit 130' SIGINT SIGTERM

echo "================================="
echo "START TEST"
echo "================================="

# =========================
# PORT FORWARD GRAFANA
# =========================

echo ""
echo "Avvio port-forward Grafana..."

nohup kubectl port-forward \
-n "$MONITORING_NAMESPACE" \
svc/monitoring-grafana \
3000:80 \
> /tmp/grafana-portforward.log 2>&1 &

GRAFANA_PID=$!

sleep 5

echo "Grafana disponibile:"
echo "http://localhost:3000"


# =========================
# FUNZIONE CREAZIONE WRK POD
# =========================

create_wrk_pod() {

    echo ""
    echo "Creo pod wrk..."

    kubectl delete pod "$WRK_POD" \
    -n "$NAMESPACE" \
    --ignore-not-found

    kubectl run "$WRK_POD" \
    -n "$NAMESPACE" \
    --image=alpine \
    --restart=Never \
    --overrides='
    {
      "spec": {
        "nodeSelector": {
          "kubernetes.io/hostname": "consumer-worker"
        }
      }
    }' \
    --command -- sleep 3600

    echo "Attendo pod Ready..."

    kubectl wait \
    --for=condition=Ready \
    pod/"$WRK_POD" \
    -n "$NAMESPACE" \
    --timeout=60s

    echo ""
    echo "Nodo wrk:"
    kubectl get pod "$WRK_POD" \
    -n "$NAMESPACE" \
    -o wide

    echo ""
    echo "Installazione wrk..."

    kubectl exec \
    -n "$NAMESPACE" \
    "$WRK_POD" -- \
    apk add --no-cache wrk
}

# =========================
# ESECUZIONE RUN
# =========================

for RUN in $(seq 1 "$RUNS")
do

    echo ""
    echo "================================="
    echo "RUN $RUN / $RUNS"
    echo "================================="

    create_wrk_pod

    RESULT_FILE="wrk_t${THREADS}_c${CONNECTIONS}_run${RUN}.txt"

    echo ""
    echo "Avvio WRK..."

    RUN_START_TS=$(date +%s)

    kubectl exec \
    -n "$NAMESPACE" \
    "$WRK_POD" -- sh -c "
    {
        echo 'Test: ${TEST}'
        echo 'Configuration: t${THREADS} c${CONNECTIONS} d${DURATION}'
        echo 'Run: ${RUN}'
        date

        wrk \
        -t${THREADS} \
        -c${CONNECTIONS} \
        -d${DURATION} \
        --timeout ${WRK_TIMEOUT} \
        --latency \
        ${TARGET_URL}

    } > /tmp/${RESULT_FILE}
    "

    RUN_END_TS=$(date +%s)

    echo "start=$RUN_START_TS" \
    > "$OUTPUT_DIR/run${RUN}_times.txt"

    echo "end=$RUN_END_TS" \
    >> "$OUTPUT_DIR/run${RUN}_times.txt"

    echo ""
    echo "Copio risultato..."

    kubectl cp \
    -n "$NAMESPACE" \
    "$WRK_POD:/tmp/$RESULT_FILE" \
    "$OUTPUT_DIR/$RESULT_FILE"

    echo "Run ${RUN} completata."

    echo ""
    echo "Elimino pod wrk..."

    kubectl delete pod \
    "$WRK_POD" \
    -n "$NAMESPACE" \
    --ignore-not-found

    # piccolo tempo per terminare le risorse Kubernetes
    if [ "$RUN" -lt "$RUNS" ]; then
        echo "Attendo ${COOLDOWN} secondi prima della prossima RUN..."
        sleep $COOLDOWN
    fi
done

echo ""
echo "================================="
echo "TEST COMPLETATO"
echo "Output:"
echo "$OUTPUT_DIR"
echo "================================="