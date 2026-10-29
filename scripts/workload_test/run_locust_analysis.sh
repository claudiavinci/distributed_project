#!/bin/bash

# Uso:
# ./run_analysis.sh
# ./run_analysis.sh 100 300 400

set -e

# =====================================
# CONFIG
# =====================================

source configs/exp_config.conf

REQUIRED_VARS=(
  TEST
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

# =====================================
# USER LEVELS
# =====================================

if [ -z "${USERS[*]:-}" ]; then
    echo "Nessun livello utenti definito"
    exit 1
fi
read -r -a USER_LIST <<< "${USERS[*]}"

# =====================================
# PATH
# =====================================

export KUBECONFIG="$(pwd)/consumer-config"

VENV="$(pwd)/venv"

PROM_COLLECT="$(pwd)/scripts/analysis/prometheus_metrics.py"

PROM_SUMMARY="$(pwd)/scripts/analysis/prometheus_summary.py"

LOCUST_SUMMARY="$(pwd)/scripts/analysis/locust_summary.py"

RESULTS_DIR="$(pwd)/results/${TEST}/workload_test"

RUNS_TEMPLATE="${RESULTS_DIR}/U{users}/raw"

METRICS_TEMPLATE="${RESULTS_DIR}/U{users}/metrics_csv"

runs_dir(){
    echo "${RUNS_TEMPLATE//\{users\}/$1}"
}

metrics_dir(){
    echo "${METRICS_TEMPLATE//\{users\}/$1}"
}

# =====================================
# CLEANUP
# =====================================

PORT_FORWARD_PID=""

cleanup(){
    echo ""
    echo "Pulizia"
    if [ -n "$PORT_FORWARD_PID" ]; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT SIGINT SIGTERM

# =====================================
# CHECK CARTELLE
# =====================================

echo "Livelli utenti:"
echo "${USER_LIST[*]}"

for U in "${USER_LIST[@]}"; do
    if [ ! -d "$(runs_dir "$U")" ]; then
        echo "Cartella run mancante:"
        echo "$(runs_dir "$U")"
        exit 1
    fi
done

# =====================================
# VENV
# =====================================

source "$VENV/bin/activate"

# =====================================
# PROMETHEUS PORT FORWARD
# =====================================

echo ""
echo "Avvio Prometheus"

kubectl port-forward \
-n "$MONITORING_NAMESPACE" \
svc/"$PROMETHEUS_SERVICE" \
${PROMETHEUS_PORT}:${PROMETHEUS_PORT} &

PORT_FORWARD_PID=$!

sleep 5

# =====================================
# COLLECT PROMETHEUS
# =====================================

for U in "${USER_LIST[@]}"; do

    RUNS_DIR="$(runs_dir "$U")"
    OUTPUT_DIR="$(metrics_dir "$U")"
    OUTPUT_PREFIX="${OUTPUT_DIR}/U${U}"

    mkdir -p "$OUTPUT_DIR"

    echo ""
    echo "================================="
    echo "Prometheus U${U}"
    echo "================================="

    python "$PROM_COLLECT" \
        --namespace "$NAMESPACE" \
        --runs-dir "$RUNS_DIR" \
        --output-prefix "$OUTPUT_PREFIX" \
        --prometheus-url "$PROMETHEUS_URL"

done

# =====================================
# PROMETHEUS SUMMARY
# =====================================

echo ""
echo "================================="
echo "Summary Prometheus"
echo "================================="

python "$PROM_SUMMARY" \
"$RESULTS_DIR"

# =====================================
# LOCUST SUMMARY
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
echo ""
echo "Output finali:"
echo ""

echo "${RESULTS_DIR}/prometheus_pods_summary.csv"
echo "${RESULTS_DIR}/prometheus_nodes_summary.csv"
echo "${RESULTS_DIR}/stats_summary.csv"