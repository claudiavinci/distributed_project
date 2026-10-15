#!/bin/bash

set -euo pipefail

# =========================
# CARICAMENTO CONFIG
# =========================

source configs/exp_config.conf

REQUIRED_VARS=(
  TEST DURATION RUNS COOLDOWN CONNECTIONS
  NAMESPACE MONITORING_NAMESPACE K6_POD TARGET_URL WRK_TIMEOUT
  RATES WARMUP_RATE WARMUP_DURATION
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
BASE_OUTPUT_DIR="$(pwd)/results/${TEST}/c${CONNECTIONS}"

read -r -a RATE_LIST <<< "$RATES"
TOTAL_RUNS=$(( ${#RATE_LIST[@]} * RUNS ))
RUN_COUNTER=0

# =========================
# SCRIPT K6 (ciclo aperto)
# =========================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K6_SCRIPT="${SCRIPT_DIR}/k6_open_loop.js"

if [ ! -f "$K6_SCRIPT" ]; then
    echo "Errore: file k6 non trovato: $K6_SCRIPT"
    exit 1
fi

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

    kubectl delete pod "$K6_POD" \
        -n "$NAMESPACE" \
        --ignore-not-found || true

    echo "Pulizia completata."
}

trap cleanup EXIT
trap 'exit 130' SIGINT SIGTERM

echo "================================="
echo "START TEST (k6, ciclo aperto)"
echo "Rate: ${RATES} req/s"
echo "Run per rate: ${RUNS}"
echo "Immagine: ${K6_IMAGE}"
echo "VU: pre=${PRE_VUS} max=${MAX_VUS}"
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

echo "Grafana disponibile: http://localhost:3000"

# =========================
# FUNZIONI
# =========================

create_K6_POD() {

    echo ""
    echo "Creo pod k6..."

    kubectl delete pod "$K6_POD" \
        -n "$NAMESPACE" \
        --ignore-not-found

    kubectl run "$K6_POD" \
        -n "$NAMESPACE" \
        --image="$K6_IMAGE" \
        --image-pull-policy=IfNotPresent \
        --restart=Never \
        --overrides='
        {
          "spec": {
            "nodeSelector": {
              "kubernetes.io/hostname": "consumer-worker"
            }
          }
        }' \
        --command -- sleep infinity

    echo "Attendo pod Ready..."

    kubectl wait \
        --for=condition=Ready \
        pod/"$K6_POD" \
        -n "$NAMESPACE" \
        --timeout=180s

    if ! kubectl exec -n "$NAMESPACE" "$K6_POD" -- k6 version; then
        echo "Errore: k6 non eseguibile nell'immagine $K6_IMAGE"
        exit 1
    fi

    echo ""
    echo "Nodo k6:"
    kubectl get pod "$K6_POD" -n "$NAMESPACE" -o wide
}

# uso: run_k6 <rate> <durata>
run_k6() {
    kubectl exec -i -n "$NAMESPACE" "$K6_POD" -- \
        k6 run --quiet --no-usage-report \
        -e RATE="$1" \
        -e DURATION="$2" \
        -e TARGET_URL="$TARGET_URL" \
        -e REQ_TIMEOUT="$WRK_TIMEOUT" \
        -e PRE_VUS="$PRE_VUS" \
        -e MAX_VUS="$MAX_VUS" \
        --summary-export=/tmp/summary.json \
        - < "$K6_SCRIPT"
}

# =========================
# ESECUZIONE: per ogni rate, RUNS ripetizioni (pod nuovo a ogni run)
# =========================

for RATE in "${RATE_LIST[@]}"
do

    OUTPUT_DIR="${BASE_OUTPUT_DIR}/R${RATE}/raw"
    mkdir -p "$OUTPUT_DIR"

    for RUN in $(seq 1 "$RUNS")
    do

        echo ""
        echo "================================="
        echo "RATE ${RATE} req/s - RUN ${RUN} / ${RUNS}"
        echo "================================="

        create_K6_POD

        # Warm-up del sistema sotto test (non entra nei timestamp della run)
        echo ""
        echo "Warm-up: ${WARMUP_RATE} req/s per ${WARMUP_DURATION}..."

        run_k6 "$WARMUP_RATE" "$WARMUP_DURATION" > /dev/null 2>&1

        RESULT_FILE="k6_R${RATE}_run${RUN}.txt"
        SUMMARY_FILE="k6_R${RATE}_run${RUN}_summary.json"

        echo ""
        echo "Avvio misura..."

        RUN_START_TS=$(date +%s)

        {
            echo "Test: ${TEST}"
            echo "Configuration: k6 constant-arrival-rate R${RATE} d${DURATION} VUs ${PRE_VUS}-${MAX_VUS}"
            echo "Run: ${RUN}"
            date
            echo ""

            run_k6 "$RATE" "$DURATION" 2>&1
        } > "$OUTPUT_DIR/$RESULT_FILE"

        RUN_END_TS=$(date +%s)

        {
            echo "start=$RUN_START_TS"
            echo "end=$RUN_END_TS"
        } > "$OUTPUT_DIR/run${RUN}_times.txt"

        # riepilogo in formato JSON (comodo per l'analisi)
        kubectl exec -n "$NAMESPACE" "$K6_POD" -- cat /tmp/summary.json \
            > "$OUTPUT_DIR/$SUMMARY_FILE" || echo "Attenzione: summary JSON non recuperato"

        echo "Run completata. Rate richiesto: ${RATE} req/s"
        grep -E "http_reqs|http_req_duration|http_req_failed|dropped_iterations" \
            "$OUTPUT_DIR/$RESULT_FILE" || true

        echo ""
        echo "Elimino pod k6..."

        kubectl delete pod "$K6_POD" \
            -n "$NAMESPACE" \
            --ignore-not-found

        RUN_COUNTER=$((RUN_COUNTER + 1))

        if [ "$RUN_COUNTER" -lt "$TOTAL_RUNS" ]; then
            echo "Attendo ${COOLDOWN} secondi prima della prossima run..."
            sleep "$COOLDOWN"
        fi
    done
done

echo ""
echo "================================="
echo "TEST COMPLETATO"
echo "Output:"
echo "$BASE_OUTPUT_DIR"
echo "================================="