#!/bin/bash

set -e

# =====================================
# CONFIG
# =====================================

source configs/exp_config.conf

REQUIRED_VARS=(
    TEST
    USERS_LIST
    NAMESPACE
    MONITORING_NAMESPACE
    PROMETHEUS_URL
    PROMETHEUS_SERVICE
    PROMETHEUS_PORT
)

for v in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!v:-}" ]; then
        echo "Variabile mancante: $v"
        exit 1
    fi
done

read -r -a USER_LIST <<< "${USERS_LIST}"

# =====================================
# PATH
# =====================================

export KUBECONFIG="$(pwd)/consumer-config"

VENV="$(pwd)/venv"

PROM_COLLECT="$(pwd)/scripts/analysis/prometheus_metrics.py"
PROM_SUMMARY="$(pwd)/scripts/analysis/prometheus_summary.py"
LOCUST_SUMMARY="$(pwd)/scripts/analysis/locust_summary.py"

RESULTS_DIR="$(pwd)/results/${TEST}/load_test"
PLOT_DIR="${RESULTS_DIR}/plots"

# =====================================
# CLEANUP
# =====================================

PORT_FORWARD_PID=""

cleanup() {
    echo ""
    echo "Pulizia"
    if [ -n "$PORT_FORWARD_PID" ]; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT SIGINT SIGTERM

# =====================================
# CONTROLLO CARTELLE
# =====================================

echo "Livelli utenti:"
echo "${USER_LIST[*]}"

for U in "${USER_LIST[@]}"; do
    if [ ! -d "${RESULTS_DIR}/U${U}/raw" ]; then
        echo "Cartella mancante:"
        echo "${RESULTS_DIR}/U${U}/raw"
        exit 1
    fi
done

# =====================================
# ATTIVAZIONE VENV
# =====================================

source "$VENV/bin/activate"

# =====================================
# PORT FORWARD PROMETHEUS
# =====================================

echo ""
echo "================================="
echo "Avvio Prometheus"
echo "================================="

kubectl port-forward \
    -n "$MONITORING_NAMESPACE" \
    svc/"$PROMETHEUS_SERVICE" \
    ${PROMETHEUS_PORT}:${PROMETHEUS_PORT} &

PORT_FORWARD_PID=$!

sleep 5

# =====================================
# RACCOLTA METRICHE PROMETHEUS
# =====================================

echo ""
echo "================================="
echo "Raccolta metriche Prometheus"
echo "================================="

python "$PROM_COLLECT" \
    --base-dir "$RESULTS_DIR" \
    --namespace "$NAMESPACE" \
    --prometheus-url "$PROMETHEUS_URL"

echo ""
echo "================================="
echo "Raccolta completata."
echo "Summary metriche Prometheus"
echo "================================="

# =====================================
# SUMMARY PROMETHEUS
# =====================================

python "$PROM_SUMMARY" \
    "$RESULTS_DIR"

# =====================================
# SUMMARY LOCUST
# =====================================

echo ""
echo "================================="
echo "Summary Locust"
echo "================================="

python "$LOCUST_SUMMARY" \
    "$RESULTS_DIR"

# =====================================
# FINE
# =====================================

echo ""
echo "================================="
echo "ANALISI COMPLETATA"
echo "================================="
