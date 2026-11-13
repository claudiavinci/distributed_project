#!/usr/bin/env bash

# Monitoraggio fault worker provider.
# Salvataggio in append con timestamp.

set -euo pipefail

# =====================================
# CONFIGURAZIONE
# =====================================

source configs/exp_config.conf
source configs/liqo_config.conf

INTERVAL="${MONITOR_INTERVAL:-10}"

CONSUMER_CONFIG="$KUBECONFIG"
PROVIDER_CONFIG="$REMOTE_KUBECONFIG"

OUTPUT_DIR="${OUTPUT_DIR:-results/${TEST}/fault_monitor}"

mkdir -p "$OUTPUT_DIR/consumer" "$OUTPUT_DIR/provider"

# =====================================
# FUNZIONI COMUNI
# =====================================

timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

consumer() {
    kubectl --kubeconfig="$CONSUMER_CONFIG" \
        --request-timeout=5s "$@"
}

provider() {
    kubectl --kubeconfig="$PROVIDER_CONFIG" \
        --request-timeout=5s "$@"
}

append_command() {
    local file="$1"
    local timestamp="$2"
    shift 2

    {
        echo
        echo "========================================"
        echo "TIMESTAMP: $timestamp"
        echo "========================================"

        "$@" || echo "ERRORE: comando fallito"

    } >> "$file" 2>&1
}

# =====================================
# RACCOLTA SNAPSHOT
# =====================================

collect_snapshot() {
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    echo "[$timestamp] Raccolta stato cluster..."

    # CONSUMER

    append_command "$OUTPUT_DIR/consumer/nodes.txt" "$timestamp" \
        consumer get nodes -o wide

    append_command "$OUTPUT_DIR/consumer/pods.txt" "$timestamp" \
        consumer get pods -n "$NAMESPACE" -o wide

    append_command "$OUTPUT_DIR/consumer/events.txt" "$timestamp" \
        consumer get events -n "$NAMESPACE" \
        --sort-by=.lastTimestamp

    for svc in frontend currencyservice paymentservice; do
        append_command "$OUTPUT_DIR/consumer/endpoints_${svc}.txt" "$timestamp" \
            consumer get endpointslices -n "$NAMESPACE" \
            -l "kubernetes.io/service-name=$svc" -o yaml
    done

    # PROVIDER

    append_command "$OUTPUT_DIR/provider/nodes.txt" "$timestamp" \
        provider get nodes -o wide

    append_command "$OUTPUT_DIR/provider/pods.txt" "$timestamp" \
        provider get pods -n "$NAMESPACE" -o wide

    append_command "$OUTPUT_DIR/provider/shadowpods.txt" "$timestamp" \
        provider get shadowpods -n "$NAMESPACE"

    append_command "$OUTPUT_DIR/provider/liqo_pods.txt" "$timestamp" \
        provider get pods -n liqo -o wide

    append_command "$OUTPUT_DIR/provider/events.txt" "$timestamp" \
        provider get events -n "$NAMESPACE" \
        --sort-by=.lastTimestamp
}

# =====================================
# MONITORAGGIO CONTINUO
# =====================================

echo "================================="
echo "Avvio monitoraggio cluster"
echo "Intervallo: ${INTERVAL}s"
echo "Output: $OUTPUT_DIR"
echo "================================="

while true; do
    start=$(date +%s)

    collect_snapshot

    elapsed=$(( $(date +%s) - start ))
    remaining=$(( INTERVAL - elapsed ))

    if (( remaining > 0 )); then
        sleep "$remaining"
    fi
done