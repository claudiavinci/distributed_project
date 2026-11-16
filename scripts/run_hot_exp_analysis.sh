
#!/usr/bin/env bash

# Analisi esperimenti a caldo:
# - hot offloading
# - hot unoffloading
# - fault test

set -euo pipefail

# =====================================
# CONFIGURAZIONE
# =====================================

source configs/exp_config.conf

: "${TEST:?Variabile TEST non definita}"

BASE_DIR="results/${TEST}/load_test"
RAW_DIR="${BASE_DIR}/U400/raw"
PLOTS_DIR="${BASE_DIR}/plots"

PREFIX="U400_run1"

# =====================================
# IDENTIFICAZIONE ESPERIMENTO
# =====================================

if [[ -f "${RAW_DIR}/${PREFIX}_offload_events.csv" ]]; then
    TYPE="offload"
elif [[ -f "${RAW_DIR}/${PREFIX}_return_events.csv" ]]; then
    TYPE="return"
elif [[ -f "${RAW_DIR}/${PREFIX}_fault_events.csv" ]]; then
    TYPE="fault"
else
    echo "Errore: nessun file eventi trovato in $RAW_DIR"
    exit 1
fi

EVENTS="${RAW_DIR}/${PREFIX}_${TYPE}_events.csv"

# =====================================
# STORICO LOCUST
# =====================================

HISTORY="${RAW_DIR}/${PREFIX}_${TYPE}_stats_history.csv"

if [[ ! -f "$HISTORY" ]]; then
    HISTORY="${RAW_DIR}/${PREFIX}_stats_history.csv"
fi

# =====================================
# VERIFICA
# =====================================

if [[ ! -f "$HISTORY" ]]; then
    echo "Errore: storico Locust non trovato in $RAW_DIR"
    exit 1
fi

# =====================================
# ANALISI
# =====================================
VENV=$(pwd)/venv
source "$VENV/bin/activate"


echo "================================="
echo "Analisi esperimento: $TYPE"
echo "Test: $TEST"
echo "Utenti: 400"
echo "================================="

python3 "$(pwd)/scripts/analysis/plot_hot_experiments.py" \
    --type "$TYPE" \
    --history "$HISTORY" \
    --events "$EVENTS" \
    --plots-dir "$PLOTS_DIR"

echo
echo "Analisi completata."
echo "Metriche: $METRICS_DIR"
echo "Grafici: $PLOTS_DIR"
