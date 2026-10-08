#!/bin/bash

set -e

# =====================================
# CARICAMENTO CONFIG ESPERIMENTO
# =====================================

source workload_exp_config.conf

if [ -z "$TEST" ] || [ -z "$CONNECTIONS" ]; then
    echo "Errore: configurazione esperimento incompleta"
    exit 1
fi

# =====================================
# CONFIGURAZIONE ESPERIMENTO
# =====================================

export KUBECONFIG="$(pwd)/consumer-config"

# Python

VENV="$(pwd)/venv"

PYTHON_SCRIPT="$(pwd)/analysis/collect_prometheus_metrics.py"

# Esperimento da analizzare

RUNS_DIR="experiments/${TEST}/workload_test/c${CONNECTIONS}/raw"

OUTPUT_DIR="experiments/${TEST}/workload_test/c${CONNECTIONS}/metrics_csv"

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
    echo "================================="
    echo "Pulizia completata"
    echo "================================="
}

trap cleanup EXIT SIGINT SIGTERM

# =====================================
# CONTROLLO CARTELLA
# =====================================

if [ ! -d "$RUNS_DIR" ]; then
    echo "Errore: cartella run non trovata"
    echo "$RUNS_DIR"
    exit 1
fi

echo "================================="
echo "Avvio Prometheus port-forward"
echo "================================="

# =====================================
# PORT FORWARD PROMETHEUS
# =====================================

kubectl port-forward \
-n "$MONITORING_NAMESPACE" \
svc/"$PROMETHEUS_SERVICE" \
${PROMETHEUS_PORT}:${PROMETHEUS_PORT} &

PORT_FORWARD_PID=$!

echo "Prometheus disponibile su localhost:${PROMETHEUS_PORT}"

# Aspetta avvio

sleep 5

# =====================================
# ATTIVAZIONE VENV
# =====================================

echo ""
echo "Attivo ambiente Python..."
source "$VENV/bin/activate"

# =====================================
# RACCOLTA METRICHE
# =====================================

echo ""
echo "================================="
echo "Raccolta metriche Prometheus"
echo "================================="

echo "Esperimento:"
echo "$TEST"

echo "Configurazione:"
echo "c=$CONNECTIONS"

echo "Directory run:"
echo "$RUNS_DIR"

echo ""

python "$PYTHON_SCRIPT" \
--namespace "$NAMESPACE" \
--runs-dir "$RUNS_DIR" \
--output-prefix "$OUTPUT_PREFIX"


