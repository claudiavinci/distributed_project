#!/bin/bash

set -e

# =====================================
# CARICAMENTO CONFIG ESPERIMENTO
# =====================================

source configs/exp_config.conf

REQUIRED_VARS=(
  TEST CONNECTIONS NAMESPACE MONITORING_NAMESPACE PROMETHEUS_URL PROMETHEUS_SERVICE PROMETHEUS_PORT
)

for v in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!v:-}" ]; then
        echo "Errore: variabile mancante in exp_config.conf: $v"
        exit 1
    fi
done

# =====================================
# CONFIGURAZIONE
# =====================================

export KUBECONFIG="$(pwd)/consumer-config"

VENV="$(pwd)/venv"

PROM_SCRIPT="$(pwd)/scripts/analysis/collect_prometheus_metrics.py"
WRK_SCRIPT="$(pwd)/scripts/analysis/wrk_test.py"

BASE_DIR="$(pwd)/results/${TEST}/c${CONNECTIONS}"

RUNS_DIR="${BASE_DIR}/raw"

OUTPUT_DIR="${BASE_DIR}/metrics_csv"

mkdir -p "$OUTPUT_DIR"

OUTPUT_PREFIX="${OUTPUT_DIR}/c${CONNECTIONS}"

# =====================================
# CLEANUP
# =====================================

PORT_FORWARD_PID=""

cleanup(){

    echo ""
    echo "================================="
    echo "Pulizia"
    echo "================================="

    if [ -n "$PORT_FORWARD_PID" ]; then
        echo "Chiusura port-forward Prometheus..."
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
    echo "Pulizia completata"
}

trap cleanup EXIT SIGINT SIGTERM

# =====================================
# CONTROLLO CARTELLA
# =====================================

if [ ! -d "$RUNS_DIR" ]; then
    echo "Errore: cartella run non trovata:"
    echo "$RUNS_DIR"
    exit 1
fi

# =====================================
# PORT FORWARD PROMETHEUS
# =====================================

echo ""
echo "================================="
echo "Avvio Prometheus port-forward"
echo "================================="

kubectl port-forward \
-n "$MONITORING_NAMESPACE" \
svc/"$PROMETHEUS_SERVICE" \
${PROMETHEUS_PORT}:${PROMETHEUS_PORT} &

PORT_FORWARD_PID=$!

echo "Prometheus disponibile su ${PROMETHEUS_URL}"

sleep 5

# =====================================
# ATTIVAZIONE VENV
# =====================================

echo ""
echo "Attivo ambiente Python..."

if [ ! -d "$VENV" ]; then
    echo "Errore: virtual environment non trovato:"
    echo "$VENV"
    exit 1
fi

source "$VENV/bin/activate"

# =====================================
# ANALISI PROMETHEUS
# =====================================

echo ""
echo "================================="
echo "Analisi metriche Prometheus"
echo "================================="

python "$PROM_SCRIPT" \
--namespace "$NAMESPACE" \
--runs-dir "$RUNS_DIR" \
--output-prefix "$OUTPUT_PREFIX" \
--prometheus-url "$PROMETHEUS_URL"

# =====================================
# ANALISI WRK
# =====================================

echo ""
echo "================================="
echo "Analisi risultati WRK"
echo "================================="

python "$WRK_SCRIPT" \
--runs-dir "$RUNS_DIR" \
--output-dir "$OUTPUT_DIR" \
--configuration "c${CONNECTIONS}"

echo ""
echo "================================="
echo "ANALISI COMPLETATA"
echo "================================="

echo ""
echo "Output generati in:"
echo "$OUTPUT_DIR"