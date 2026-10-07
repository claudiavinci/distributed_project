#!/bin/bash

set -e

# =====================================
# CONFIGURAZIONE ESPERIMENTO
# =====================================

export KUBECONFIG="$(pwd)/consumer-config"

# Applicazione Kubernetes

APP_NAMESPACE="shop"

# Prometheus

MONITORING_NAMESPACE="monitoring"
PROMETHEUS_SERVICE="monitoring-kube-prometheus-prometheus"
PROMETHEUS_PORT=9090

# Python

VENV="$(pwd)/venv"

PYTHON_SCRIPT="$(pwd)/analysis/collect_prometheus_metrics.py"

# Esperimento da analizzare

TEST_NAME="baseline"

CONNECTIONS=5000

RUNS_DIR="experiments/${TEST_NAME}/workload_test/c${CONNECTIONS}/raw"

OUTPUT_DIR="experiments/${TEST_NAME}/workload_test/c${CONNECTIONS}/metrics_csv"

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
echo "$TEST_NAME"

echo "Configurazione:"
echo "c=$CONNECTIONS"

echo "Directory run:"
echo "$RUNS_DIR"

echo ""

python "$PYTHON_SCRIPT" \
--namespace "$APP_NAMESPACE" \
--runs-dir "$RUNS_DIR" \
--output-prefix "$OUTPUT_PREFIX"


