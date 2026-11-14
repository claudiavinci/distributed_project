
#!/usr/bin/env bash

# Offloading libero a caldo dei workload Liqo sotto carico Locust.
# Dopo l'abilitazione dell'offloading, forza una nuova schedulazione
# dei Deployment selezionati mediante rollout restart.

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

OFFLOAD_AT=120
OFFLOAD_OBSERVE=600
POST_OFFLOAD_OBSERVE=120

MONITOR_INTERVAL=10
READY_TIMEOUT=300
POLL_INTERVAL=2

TOTAL_TIME=$((OFFLOAD_AT + OFFLOAD_OBSERVE + POST_OFFLOAD_OBSERVE + 45))

read -r -a DEPLOY_LIST <<< "${DEPLOYMENTS_LIST:-}"

CONSUMER_CONFIG="${KUBECONFIG:-}"
PROVIDER_CONFIG="${REMOTE_KUBECONFIG:-}"

LOADGEN_DEPLOY="loadgenerator"
LOCUSTFILE="/tmp/locustfile.py"

# =====================================
# OUTPUT E MONITORAGGIO
# =====================================

MONITOR_SCRIPT="scripts/monitor_cluster.sh"

OUTPUT_DIR="$(pwd)/results/${TEST}/load_test/U${USERS}"
RAW_DIR="$OUTPUT_DIR/raw"

PREFIX="U${USERS}_run1"

EVENTS="$RAW_DIR/${PREFIX}_offload_events.csv"
DURATION_FILE="$RAW_DIR/${PREFIX}_offload_duration.txt"
PLACEMENT_FILE="$RAW_DIR/${PREFIX}_placement.csv"

CSV_NAME="offload"
MONITOR_SUBDIR="offload_monitor/run1"

# =====================================
# STATO
# =====================================

POD_CREATED=0
LOCUST_PID=""
MONITOR_PID=""

LOCUST_STATUS=0
MOVED_COUNT=0

FIRST_REMOTE_MS=0
LAST_REMOTE_MS=0

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
# RIAVVIO WORKLOAD
# =====================================

restart_workloads() {
    local deployment

    echo "Riavvio Deployment per nuova schedulazione..."

    log_event "ROLLOUT_RESTART_START"

    for deployment in "${DEPLOY_LIST[@]}"; do
        echo "Rollout restart: $deployment"

        consumer rollout restart \
            "deployment/$deployment" \
            -n "$NAMESPACE"
    done

    log_event "ROLLOUT_RESTART_COMPLETED"
}

# =====================================
# OSSERVAZIONE OFFLOADING LIBERO
# =====================================

observe_offloading() {
    local deadline=$((SECONDS + OFFLOAD_OBSERVE))
    local deployment placement now
    local -A moved=()

    printf 'deployment,first_remote_ready_ms\n' > "$PLACEMENT_FILE"

    echo "Osservo i Deployment trasferiti sul VirtualNode..."

    while (( SECONDS < deadline )); do

        for deployment in "${DEPLOY_LIST[@]}"; do

            [[ -z "${moved[$deployment]:-}" ]] || continue

            placement="$(placement_of "$deployment")" || continue

            if [[ "$placement" == "remote" ]]; then

                now="$(epoch_ms)"

                moved[$deployment]=1
                MOVED_COUNT=$((MOVED_COUNT + 1))

                if (( FIRST_REMOTE_MS == 0 )); then
                    FIRST_REMOTE_MS="$now"
                    log_event "FIRST_REMOTE_READY"
                fi

                LAST_REMOTE_MS="$now"

                log_event "DEPLOYMENT_REMOTE_READY:$deployment"

                printf '%s,%s\n' \
                    "$deployment" \
                    "$((now - OFFLOAD_START_MS))" \
                    >> "$PLACEMENT_FILE"
            fi
        done

        sleep "$POLL_INTERVAL"
    done

    # Registra anche i Deployment mai osservati sul provider.
    for deployment in "${DEPLOY_LIST[@]}"; do
        if [[ -z "${moved[$deployment]:-}" ]]; then
            printf '%s,\n' "$deployment" >> "$PLACEMENT_FILE"
        fi
    done

    log_event "OFFLOAD_OBSERVATION_END"
}

# =====================================
# INIZIO ESPERIMENTO
# =====================================

echo ""
echo "================================="
echo "LIQO HOT OFFLOADING - LIBERO"
echo "================================="
echo "Namespace: $NAMESPACE"
echo "Utenti: $USERS"
echo "Deployment osservati: ${DEPLOY_LIST[*]}"
echo "Offloading dopo: ${OFFLOAD_AT}s"
echo "Finestra migrazione: ${OFFLOAD_OBSERVE}s"
echo "Osservazione finale: ${POST_OFFLOAD_OBSERVE}s"
echo "Durata Locust: ${TOTAL_TIME}s"
echo "Output: $OUTPUT_DIR"
echo "================================="

# =====================================
# VERIFICHE INIZIALI
# =====================================

check_app_ready || {
    echo "Errore: applicazione non disponibile"
    exit 1
}

TARGET_LIST=("${DEPLOY_LIST[@]}")

check_placement "local" || {
    echo "Errore: alcuni Deployment non sono inizialmente locali"
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

# Evita di mescolare dati di esecuzioni precedenti.
rm -rf \
    "$OUTPUT_DIR/$MONITOR_SUBDIR/consumer" \
    "$OUTPUT_DIR/$MONITOR_SUBDIR/provider"

start_monitor

# =====================================
# AVVIO LOCUST
# =====================================

echo "Avvio Locust con $USERS utenti..."

RUN_START_TS=$(date +%s)

log_event "LOCUST_START"

run_locust \
    "$USERS" \
    "$TOTAL_TIME" \
    /tmp/offload \
    > "$RAW_DIR/${PREFIX}.txt" 2>&1 &

LOCUST_PID=$!

# =====================================
# FASE 1 - FUNZIONAMENTO NORMALE
# =====================================

echo "Attendo ${OFFLOAD_AT}s prima dell'offloading..."

sleep "$OFFLOAD_AT"

# =====================================
# FASE 2 - ABILITAZIONE OFFLOADING
# =====================================

echo ""
echo "OFFLOAD NAMESPACE"

log_event "OFFLOAD_COMMAND_START"

OFFLOAD_START_MS=$(epoch_ms)

liqoctl offload namespace "$NAMESPACE" --skip-confirm

COMMAND_END_MS=$(epoch_ms)

log_event "OFFLOAD_ENABLED"

# =====================================
# FASE 3 - NUOVA SCHEDULAZIONE
# =====================================

restart_workloads

# =====================================
# FASE 4 - OSSERVAZIONE MIGRAZIONE
# =====================================

observe_offloading

# =====================================
# SALVATAGGIO TEMPI
# =====================================

{
    echo "offload_command_ms=$((COMMAND_END_MS - OFFLOAD_START_MS))"
    echo "migrated_deployments=$MOVED_COUNT"

    if (( FIRST_REMOTE_MS > 0 )); then
        echo "migration_observed=yes"
        echo "first_remote_ready_ms=$((FIRST_REMOTE_MS - OFFLOAD_START_MS))"
        echo "last_observed_remote_ready_ms=$((LAST_REMOTE_MS - OFFLOAD_START_MS))"
    else
        echo "migration_observed=no"
    fi

    echo "observation_complete=yes"

} > "$DURATION_FILE"

# =====================================
# FASE 5 - OSSERVAZIONE FINALE
# =====================================

ELAPSED=$(( $(date +%s) - RUN_START_TS ))
REMAINING=$((TOTAL_TIME - ELAPSED))

if (( REMAINING > 0 )); then
    sleep "$REMAINING"
fi

log_event "POST_OFFLOAD_OBSERVATION_END"

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
    echo "Errore: applicazione non disponibile al termine"
    exit 1
}

echo ""
echo "================================="
echo "HOT OFFLOADING TEST COMPLETATO"
echo "Deployment remoti osservati: $MOVED_COUNT"
echo "Output: $OUTPUT_DIR"
echo "================================="