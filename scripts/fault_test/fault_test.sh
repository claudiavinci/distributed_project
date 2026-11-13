
#!/usr/bin/env bash

# Test di fault del worker provider sotto carico Locust.
# Una sola run: funzionamento normale, guasto e ripristino.

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
    LOCUSTFILE_LOCAL
    KUBECONFIG REMOTE_KUBECONFIG
)

for v in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!v:-}" ]]; then
        echo "Errore: variabile mancante: $v"
        exit 1
    fi
done

# =====================================
# PARAMETRI ESPERIMENTO
# =====================================

USERS="$USERS_LIST"

FAULT_AT=120
FAULT_OBSERVE=900
RECOVERY_OBSERVE=120

MONITOR_INTERVAL=10
READY_TIMEOUT=300

TOTAL_TIME=$((FAULT_AT + FAULT_OBSERVE + RECOVERY_OBSERVE + 45))

FAULT_NODE="provider-worker"

# =====================================
# CLUSTER E LOADGENERATOR
# =====================================

CONSUMER_CONFIG="$KUBECONFIG"
PROVIDER_CONFIG="$REMOTE_KUBECONFIG"

LOADGEN_DEPLOY="loadgenerator"
LOCUSTFILE="/tmp/locustfile.py"

# =====================================
# OUTPUT E MONITORAGGIO
# =====================================

MONITOR_SCRIPT="scripts/fault_test/monitor_fault.sh"

OUTPUT_DIR="$(pwd)/results/${TEST}/load_test/U${USERS}"
RAW_DIR="$OUTPUT_DIR/raw"

PREFIX="U${USERS}_run1"
EVENTS="$RAW_DIR/${PREFIX}_fault_events.csv"

MONITOR_SUBDIR="fault_monitor/run1"
CSV_NAME="fault"

mkdir -p "$RAW_DIR" "$OUTPUT_DIR/metrics_csv"

# =====================================
# STATO
# =====================================

NODE_STOPPED=0
POD_CREATED=0

LOCUST_PID=""
MONITOR_PID=""

# =====================================
# FUNZIONI COMUNI
# =====================================

source scripts/common.sh

# =====================================
# VERIFICHE PRELIMINARI
# =====================================

for file in \
    "$CONSUMER_CONFIG" \
    "$PROVIDER_CONFIG" \
    "$LOCUSTFILE_LOCAL" \
    "$MONITOR_SCRIPT"; do

    [[ -f "$file" ]] || {
        echo "Errore: file non trovato: $file"
        exit 1
    }
done

for cmd in kubectl docker python3; do
    command -v "$cmd" >/dev/null || {
        echo "Errore: comando non disponibile: $cmd"
        exit 1
    }
done

if ! docker inspect "$FAULT_NODE" >/dev/null 2>&1; then
    echo "Errore: container $FAULT_NODE non trovato"
    exit 1
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "$FAULT_NODE")" != "true" ]]; then
    echo "Errore: worker $FAULT_NODE non in esecuzione"
    exit 1
fi

# =====================================
# CLEANUP
# =====================================

cleanup_fault() {
    local status=$?

    trap - EXIT INT TERM

    echo ""
    echo "Pulizia risorse..."

    stop_monitor

    # Ripristino di emergenza del worker.
    if (( NODE_STOPPED )); then
        echo "Riavvio di emergenza: $FAULT_NODE"
        docker start "$FAULT_NODE" >/dev/null || true
        NODE_STOPPED=0
    fi

    if [[ -n "$LOCUST_PID" ]]; then
        kill "$LOCUST_PID" 2>/dev/null || true
        wait "$LOCUST_PID" 2>/dev/null || true
    fi

    if (( POD_CREATED )); then
        consumer delete pod "$LOADGEN_POD" \
            -n "$NAMESPACE" \
            --ignore-not-found \
            --wait=false >/dev/null 2>&1 || true
    fi

    exit "$status"
}

trap cleanup_fault EXIT
trap 'exit 130' INT TERM

# =====================================
# VERIFICA WORKER PROVIDER
# =====================================

check_provider_ready() {
    local deadline=$((SECONDS + READY_TIMEOUT))
    local ready

    echo "Verifico worker $FAULT_NODE..."

    while (( SECONDS < deadline )); do

        ready="$(provider get node "$FAULT_NODE" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
            --request-timeout=5s 2>/dev/null || true)"

        [[ "$ready" == "True" ]] && return 0

        sleep 5
    done

    return 1
}

# =====================================
# VERIFICA APPLICAZIONE
# =====================================

# Controlla tutti i Deployment del namespace,
# escludendo il loadgenerator.

check_app_ready() {
    local deadline=$((SECONDS + READY_TIMEOUT))

    echo "Verifico disponibilità applicazione..."

    while (( SECONDS < deadline )); do

        if consumer get deploy -n "$NAMESPACE" -o json \
            --request-timeout=5s |
            python3 -c '
import json
import sys

try:
    deployments = json.load(sys.stdin)["items"]
    loadgen = sys.argv[1]

    deployments = [
        d for d in deployments
        if d["metadata"]["name"] != loadgen
    ]

    ready = bool(deployments) and all(
        d.get("status", {}).get("availableReplicas", 0)
        >= d["spec"].get("replicas", 1)
        for d in deployments
    )

    sys.exit(0 if ready else 1)

except (ValueError, KeyError, TypeError):
    sys.exit(1)
' "$LOADGEN_DEPLOY" 2>/dev/null; then
            return 0
        fi

        sleep 5
    done

    return 1
}

# =====================================
# INIZIO ESPERIMENTO
# =====================================

printf 'timestamp,epoch_ms,event\n' > "$EVENTS"

echo ""
echo "================================="
echo "FAULT TEST LIQO"
echo "================================="
echo "Utenti: $USERS"
echo "Worker provider: $FAULT_NODE"
echo "Guasto dopo: ${FAULT_AT}s"
echo "Osservazione guasto: ${FAULT_OBSERVE}s"
echo "Osservazione recovery: ${RECOVERY_OBSERVE}s"
echo "Durata Locust: ${TOTAL_TIME}s"
echo "Monitoraggio: ${MONITOR_INTERVAL}s"
echo "Output: $OUTPUT_DIR"
echo "================================="

# =====================================
# VERIFICHE INIZIALI
# =====================================

check_provider_ready || {
    echo "Errore: worker provider non Ready"
    exit 1
}

check_app_ready || {
    echo "Errore: applicazione non disponibile"
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
    /tmp/fault \
    > "$RAW_DIR/${PREFIX}.txt" 2>&1 &

LOCUST_PID=$!

# =====================================
# FASE 1 - FUNZIONAMENTO NORMALE
# =====================================

echo "Attendo ${FAULT_AT}s prima del guasto..."

sleep "$FAULT_AT"

# =====================================
# FASE 2 - GUASTO WORKER
# =====================================

echo ""
echo "GUASTO: $FAULT_NODE"

log_event "FAULT_COMMAND_START"

NODE_STOPPED=1

docker stop --time 10 "$FAULT_NODE" >/dev/null

log_event "NODE_STOPPED"

echo "Worker arrestato."
echo "Osservazione per ${FAULT_OBSERVE}s..."

sleep "$FAULT_OBSERVE"

# =====================================
# FASE 3 - RIPRISTINO WORKER
# =====================================

echo ""
echo "RIPRISTINO WORKER"

log_event "NODE_RESTART_COMMAND"

docker start "$FAULT_NODE" >/dev/null

NODE_STOPPED=0

log_event "NODE_RESTARTED"

echo "Osservazione recovery per ${RECOVERY_OBSERVE}s..."

sleep "$RECOVERY_OBSERVE"

log_event "RECOVERY_OBSERVATION_END"

# =====================================
# COMPLETAMENTO LOCUST
# =====================================

LOCUST_STATUS=0

wait "$LOCUST_PID" || LOCUST_STATUS=$?

LOCUST_PID=""

RUN_END_TS=$(date +%s)

log_event "LOCUST_END"

# =====================================
# TIMESTAMP PROMETHEUS
# =====================================

save_run_times "$RUN_START_TS" "$RUN_END_TS"

printf 'Locust exit status: %s\n' "$LOCUST_STATUS" \
    > "$RAW_DIR/${PREFIX}_status.txt"

# =====================================
# RACCOLTA RISULTATI
# =====================================

collect_csv

save_snapshot after

stop_monitor

# =====================================
# ELIMINAZIONE LOADGENERATOR
# =====================================

consumer delete pod "$LOADGEN_POD" \
    -n "$NAMESPACE" \
    --ignore-not-found \
    --wait=true

POD_CREATED=0

# =====================================
# VERIFICA RIPRISTINO
# =====================================

echo "Verifico ripristino cluster..."

check_provider_ready || {
    echo "Errore: worker provider non recuperato"
    exit 1
}

check_app_ready || {
    echo "Errore: applicazione non recuperata"
    exit 1
}

# =====================================
# FINE ESPERIMENTO
# =====================================

echo ""
echo "================================="
echo "FAULT TEST COMPLETATO"
echo "Output: $OUTPUT_DIR"
echo "================================="
