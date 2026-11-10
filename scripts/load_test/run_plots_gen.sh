#!/bin/bash

set -e

# =====================================
# CONFIG
# =====================================

source configs/exp_config.conf

REQUIRED_VARS=(
    TEST
    TEST_COMPARE
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

# VENV="$(pwd)/venv"

NODE_TABLE_SCRIPT="$(pwd)/scripts/analysis/table_nodes_summary.py"
STATS_TABLE_SCRIPT="$(pwd)/scripts/analysis/table_stats_summary.py"
PLOT_SCRIPT="$(pwd)/scripts/analysis/plot_experiment.py"

RESULTS_DIR="$(pwd)/results/${TEST}/load_test"
PLOT_DIR="${RESULTS_DIR}/plots"

COMPARE_PLOT_DIR="${RESULTS_DIR}/plots"
RESULTS_COMPARE_DIR="$(pwd)/results/${TEST_COMPARE}/load_test"
LABEL1="T2"
LABEL2="Baseline"

# =====================================
# ATTIVAZIONE VENV
# =====================================

# source "$VENV/bin/activate"

echo ""
echo "================================="
echo "Generazione grafici"
echo "================================="

mkdir -p "$PLOT_DIR"

python3 "$PLOT_SCRIPT" \
    --stats "$RESULTS_DIR/stats_summary.csv"\
    --nodes "$RESULTS_DIR/prometheus_nodes_summary.csv" \
    --pods "$RESULTS_DIR/prometheus_pods_summary.csv" \
    --compare-stats "$RESULTS_COMPARE_DIR/stats_summary.csv" \
    --compare-nodes "$RESULTS_COMPARE_DIR/prometheus_nodes_summary.csv" \
    --label1 "$LABEL1" \
    --label2 "$LABEL2" \
    --output "$COMPARE_PLOT_DIR"

echo "Grafici salvati in: $COMPARE_PLOT_DIR"

# echo ""
# echo "================================="
# echo "Generazione tabelle"
# echo "================================="

# python3 "$NODE_TABLE_SCRIPT" \
#     "$RESULTS_DIR/prometheus_nodes_summary.csv" \
#     --output "$PLOT_DIR/nodes_table.png"


# python3 "$STATS_TABLE_SCRIPT" \
#     "$RESULTS_DIR/stats_summary.csv" \
#     --output "$PLOT_DIR/stats_table.png"

# =====================================
# FINE
# =====================================

echo ""
echo "================================="
echo "ANALISI COMPLETATA"
echo "================================="
