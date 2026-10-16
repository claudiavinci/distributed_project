#!/bin/bash

# Uso:
#   ./k6_run_analysis.sh              -> usa RATES da exp_config.conf
#   ./k6_run_analysis.sh 50 100 200   -> usa i rate passati come argomenti

set -e

# =====================================
# CARICAMENTO CONFIG ESPERIMENTO
# =====================================

source configs/exp_config.conf

REQUIRED_VARS=(
  TEST NAMESPACE MONITORING_NAMESPACE PROMETHEUS_URL PROMETHEUS_SERVICE PROMETHEUS_PORT
)

for v in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!v:-}" ]; then
        echo "Errore: variabile mancante in exp_config.conf: $v"
        exit 1
    fi
done

# RATES in exp_config.conf puo' essere una stringa ("50 100 125")
# oppure un array bash (RATES=(50 100 125))

if [ "$#" -gt 0 ]; then
    RATE_LIST=("$@")
else
    if [ -z "${RATES[*]:-}" ]; then
        echo "Errore: nessun rate. Passali come argomenti o definisci RATES in exp_config.conf"
        exit 1
    fi
    read -r -a RATE_LIST <<< "${RATES[*]}"
fi

# =====================================
# CONFIGURAZIONE
# =====================================

export KUBECONFIG="$(pwd)/consumer-config"

VENV="$(pwd)/venv"

PROM_SCRIPT="$(pwd)/scripts/analysis/collect_prometheus_metrics.py"
K6_SCRIPT="$(pwd)/scripts/analysis/k6_test.py"
K6_SUMMARY_SCRIPT="$(pwd)/scripts/analysis/k6_summary.py"

RESULTS_DIR="$(pwd)/results/${TEST}"

# Layout delle cartelle:
# {rate} viene sostituito dal valore del rate.
#
#   results/<TEST>/R<R>/raw          run*_times.txt, R<R>_run*_summary.json
#   results/<TEST>/R<R>/metrics_csv  CSV del singolo rate (Prometheus + k6)
#   results/<TEST>/k6_summary*.csv   riepilogo di tutti i rate

RUNS_DIR="${RESULTS_DIR}/R{rate}/raw"
METRICS_DIR="${RESULTS_DIR}/R{rate}/metrics_csv"

runs_dir()    { echo "${RUNS_DIR//\{rate\}/$1}"; }
metrics_dir() { echo "${METRICS_DIR//\{rate\}/$1}"; }

# glob dei CSV per-run di tutti i rate, derivato dallo stesso template
K6_RUNS_GLOB="${METRICS_DIR//\{rate\}/*}/R*_k6_runs.csv"

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
# CONTROLLO CARTELLE
# =====================================

echo "Rate da analizzare: ${RATE_LIST[*]}"

for R in "${RATE_LIST[@]}"; do
    if [ ! -d "$(runs_dir "$R")" ]; then
        echo "Errore: cartella run non trovata per rate ${R}:"
        echo "$(runs_dir "$R")"
        exit 1
    fi
done

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
# PORT FORWARD PROMETHEUS (una sola volta)
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
# ANALISI PER RATE (Prometheus + k6)
# =====================================

for R in "${RATE_LIST[@]}"; do

    RUNS_DIR="$(runs_dir "$R")"
    OUTPUT_DIR="$(metrics_dir "$R")"
    OUTPUT_PREFIX="${OUTPUT_DIR}/R${R}"

    mkdir -p "$OUTPUT_DIR"

    echo ""
    echo "================================="
    echo "Analisi metriche Prometheus (rate ${R})"
    echo "================================="

    python "$PROM_SCRIPT" \
    --namespace "$NAMESPACE" \
    --runs-dir "$RUNS_DIR" \
    --output-prefix "$OUTPUT_PREFIX" \
    --prometheus-url "$PROMETHEUS_URL"

    echo ""
    echo "================================="
    echo "Analisi risultati k6 (rate ${R})"
    echo "================================="

    python "$K6_SCRIPT" \
    --rate "$R" \
    --runs-dir "$RUNS_DIR" \
    --output-dir "$OUTPUT_DIR"

done

# =====================================
# RIEPILOGO K6 (tutti i rate presenti su disco)
# =====================================

echo ""
echo "================================="
echo "Riepilogo k6"
echo "================================="

python "$K6_SUMMARY_SCRIPT" \
--input-glob "$K6_RUNS_GLOB" \
--output-dir "$RESULTS_DIR"

echo ""
echo "================================="
echo "ANALISI COMPLETATA"
echo "================================="

echo ""
echo "CSV per rate in:"
for R in "${RATE_LIST[@]}"; do
    echo "$(metrics_dir "$R")"
done
echo ""
echo "Riepilogo k6 (una riga per rate) in:"
echo "${RESULTS_DIR}/k6_summary.csv"
echo "${RESULTS_DIR}/k6_summary_std.csv"