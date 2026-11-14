#!/usr/bin/env bash

# Rientro a caldo dei workload Liqo sotto carico Locust.

set -Eeuo pipefail

# =====================================
# CONFIGURAZIONE
# =====================================

source configs/exp_config.conf
source configs/liqo_config.conf

REQUIRED_VARS=(
    TEST NAMESPACE USERS_LIST
    LOADGEN_POD LOADGEN_NODE TARGET_URL
    RAMP_S WARMUP_USERS WARMUP_DURATION
    LOCUSTFILE_LOCAL KUBECONFIG REMOTE_KUBECONFIG
    DEPLOYMENTS_LIST
)

USERS="${USERS_LIST:-}"

RETURN_AT=120
RETURN_OBSERVE=600
POST_RETURN_OBSERVE=120

MONITOR_INTERVAL=10
READY_TIMEOUT=300
POLL_INTERVAL=2

TOTAL_TIME=$((RETURN_AT + RETURN_OBSERVE + POST_RETURN_OBSERVE + 45))

read -r -a DEPLOY_LIST <<< "${DEPLOYMENTS_LIST:-}"

OFFLOADED_LIST=()

CONSUMER_CONFIG="${KUBECONFIG:-}"
PROVIDER_CONFIG="${REMOTE_KUBECONFIG:-}"

LOADGEN_DEPLOY="loadgenerator"
LOCUSTFILE="/tmp/locustfile.py"
MONITOR_SCRIPT="scripts/monitor_cluster.sh"

OUTPUT_DIR="$(pwd)/results/${TEST}/load_test/U${USERS}"
RAW_DIR="$OUTPUT_DIR/raw"

PREFIX="U${USERS}_run1"

EVENTS="$RAW_DIR/${PREFIX}_return_events.csv"

CSV_NAME="return"
MONITOR_SUBDIR="return_monitor/run1"

# =====================================
# STATO
# =====================================

POD_CREATED=0
LOCUST_PID=""
MONITOR_PID=""

RETURN_OK=0
LOCUST_STATUS=0

# =====================================
# FUNZIONI CONDIVISE
# =====================================

source scripts/common.sh

check_requirements

trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$RAW_DIR" "$OUTPUT_DIR/metrics_csv"

printf 'timestamp,epoch_ms,event\n' > "$EVENTS"

# =====================================
# RILEVAMENTO WORKLOAD OFFLOADATI
# =====================================

detect_offloaded() {
    local deployment placement

    OFFLOADED_LIST=()

    for deployment in "${DEPLOY_LIST[@]}"; do

        placement="$(placement_of "$deployment")" || return 1

        if [[ "$placement" == "remote" ]]; then
            OFFLOADED_LIST+=("$deployment")
        fi
    done

    if (( ${#OFFLOADED_LIST[@]} == 0 )); then
        echo "Errore: nessun Deployment risulta offloadato"
        return 1
    fi

    echo "Deployment offloadati: ${OFFLOADED_LIST[*]}"
}

# =====================================
# ATTESA POSIZIONAMENTO
# =====================================

wait_for_placement() {
    local expected="$1"
    local timeout="$2"
    local success_event="$3"

    local deadline=$((SECONDS + timeout))

    echo "Attendo posizionamento: $expected..."

    while (( SECONDS < deadline )); do

        if check_placement "$expected"; then
            log_event "$success_event"
            return 0
        fi

        sleep "$POLL_INTERVAL"
    done

    log_event "PLACEMENT_TIMEOUT"
    return 1
}

# =====================================
# PULIZIA SHADOW POD LIQO
# =====================================

cleanup_shadow_pods() {
    echo "Pulizia shadow Pod Liqo falliti..."

    consumer delete pods \
        -n "$NAMESPACE" \
        -l "liqo.io/shadowPod=true" \
        --field-selector='status.phase=Failed' \
        --ignore-not-found \
        --wait=false
}



# =====================================
# INIZIO ESPERIMENTO
# =====================================

echo ""
echo "================================="
echo "LIQO HOT UNOFFLOADING"
echo "================================="
echo "Namespace: $NAMESPACE"
echo "Utenti: $USERS"
echo "Deployment eleggibili: ${DEPLOY_LIST[*]}"
echo "Rientro dopo: ${RETURN_AT}s"
echo "Osservazione rientro: ${RETURN_OBSERVE}s"
echo "Osservazione finale: ${POST_RETURN_OBSERVE}s"
echo "Output: $OUTPUT_DIR"
echo "================================="

# =====================================
# VERIFICHE INIZIALI
# =====================================

check_app_ready || {
    echo "Errore: applicazione non disponibile"
    exit 1
}

detect_offloaded || {
    echo "Errore: impossibile identificare i workload offloadati"
    exit 1
}

TARGET_LIST=("${OFFLOADED_LIST[@]}")

check_placement "remote" || {
    echo "Errore: workload offloadati non Ready sul VirtualNode"
    exit 1
}

save_snapshot before

# =====================================
# LOADGENERATOR E WARM-UP
# =====================================

create_loadgen_pod

log_event "WARMUP_START"

run_locust \
    "$WARMUP_USERS" \
    "$WARMUP_DURATION" \
    /tmp/warmup \
    > "$RAW_DIR/${PREFIX}_warmup.log" 2>&1

log_event "WARMUP_END"

# =====================================
# MONITORAGGIO
# =====================================

start_monitor

# =====================================
# AVVIO LOCUST
# =====================================

RUN_START_TS=$(date +%s)

log_event "LOCUST_START"

run_locust \
    "$USERS" \
    "$TOTAL_TIME" \
    /tmp/return \
    > "$RAW_DIR/${PREFIX}.txt" 2>&1 &

LOCUST_PID=$!

# =====================================
# FASE 1 - FUNZIONAMENTO NORMALE
# =====================================

echo "Attendo ${RETURN_AT}s prima del rientro..."

sleep "$RETURN_AT"

# =====================================
# FASE 2 - UNOFFLOAD
# =====================================

echo ""
echo "UNOFFLOAD NAMESPACE"

log_event "RETURN_COMMAND_START"

START_MS=$(epoch_ms)

liqoctl unoffload namespace "$NAMESPACE" --skip-confirm

COMMAND_END_MS=$(epoch_ms)

log_event "OFFLOADING_DISABLED"

# =====================================
# FASE 3 - ATTESA RIENTRO
# =====================================

if wait_for_placement \
    "local" \
    "$RETURN_OBSERVE" \
    "WORKLOADS_LOCAL_READY"; then

    RETURN_OK=1

    END_MS=$(epoch_ms)

    log_event "RETURN_COMPLETED"

else
    log_event "RETURN_NOT_COMPLETED"
fi

# =====================================
# SALVATAGGIO TEMPI
# =====================================

{
    echo "unoffload_command_ms=$((COMMAND_END_MS - START_MS))"
    echo "return_completed=$RETURN_OK"

    if (( RETURN_OK )); then
        echo "return_duration_ms=$((END_MS - START_MS))"
        echo "workloads_ready_after_command_ms=$((END_MS - COMMAND_END_MS))"
    fi

} > "$RAW_DIR/${PREFIX}_return_duration.txt"

# =====================================
# FASE 4 - OSSERVAZIONE FINALE
# =====================================

ELAPSED=$(( $(date +%s) - RUN_START_TS ))
REMAINING=$((TOTAL_TIME - ELAPSED))

if (( REMAINING > 0 )); then
    sleep "$REMAINING"
fi

log_event "POST_RETURN_OBSERVATION_END"

# =====================================
# COMPLETAMENTO LOCUST
# =====================================

wait "$LOCUST_PID" || LOCUST_STATUS=$?
LOCUST_PID=""

RUN_END_TS=$(date +%s)

log_event "LOCUST_END"

# =====================================
# TIMESTAMP PROMETHEUS
# =====================================

save_run_times "$RUN_START_TS" "$RUN_END_TS"


# =====================================
# RACCOLTA RISULTATI
# =====================================

collect_csv

save_snapshot after

stop_monitor

# =====================================
# PULIZIA LOADGENERATOR
# =====================================

consumer delete pod "$LOADGEN_POD" \
    -n "$NAMESPACE" \
    --ignore-not-found \
    --wait=true

POD_CREATED=0

# =====================================
# VERIFICA FINALE
# =====================================

check_app_ready || {
    echo "Errore: applicazione non disponibile dopo il rientro"
    exit 1
}

if (( RETURN_OK == 0 )); then
    echo "Errore: rientro non completato"
    exit 1
fi

# Pulizia dopo la misurazione.
cleanup_shadow_pods || {
    echo "Attenzione: cleanup shadow Pod non riuscito"
}

echo ""
echo "================================="
echo "HOT UNOFFLOADING TEST COMPLETATO"
echo "Output: $OUTPUT_DIR"
echo "================================="