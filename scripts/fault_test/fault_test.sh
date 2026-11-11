#!/usr/bin/env bash

set -Eeuo pipefail

# =====================================
# CONFIGURAZIONE
# =====================================

source configs/exp_config.conf
source configs/liqo_config.conf

REQUIRED_VARS=(
    TEST NAMESPACE RUNS USERS_LIST
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
# PARAMETRI FAULT TEST
# =====================================

USERS="$USERS_LIST"

FAULT_AT=120
FAULT_OBSERVE=900
RECOVERY_OBSERVE=120

MONITOR_INTERVAL=10
READY_TIMEOUT=300

TOTAL_TIME=$((FAULT_AT + FAULT_OBSERVE + RECOVERY_OBSERVE + 45))

# Nodo Kind da arrestare (non il VirtualNode Liqo)
FAULT_NODE="provider-worker"

# =====================================
# CLUSTER
# =====================================

CONSUMER_CONFIG="$KUBECONFIG"
PROVIDER_CONFIG="$REMOTE_KUBECONFIG"

# =====================================
# LOADGENERATOR
# =====================================

LOADGEN_DEPLOY="loadgenerator"
LOADGEN_IMAGE=""

LOCUSTFILE="/tmp/locustfile.py"

# =====================================
# MONITORAGGIO
# =====================================

MONITOR_SCRIPT="scripts/fault_test/monitor_fault.sh"

OUTPUT_DIR="$(pwd)/results/${TEST}/load_test/U${USERS}"
RAW_DIR="$OUTPUT_DIR/raw"

mkdir -p "$RAW_DIR" "$OUTPUT_DIR/metrics_csv"

# =====================================
# STATO
# =====================================

NODE_STOPPED=0
POD_CREATED=0

LOCUST_PID=""
MONITOR_PID=""

PREFIX=""
FAULT_EVENTS=""

# =====================================
# FUNZIONI COMUNI
# =====================================

consumer() {
    kubectl --kubeconfig="$CONSUMER_CONFIG" "$@"
}

provider() {
    kubectl --kubeconfig="$PROVIDER_CONFIG" "$@"
}

timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

log_event() {
    printf '%s,%s\n' "$(timestamp)" "$1" |
        tee -a "$FAULT_EVENTS"
}

# =====================================
# MONITORAGGIO ESTERNO
# =====================================

start_monitor() {
    local monitor_dir="$OUTPUT_DIR/fault_monitor/run${RUN}"

    mkdir -p "$monitor_dir"

    # Evita di mescolare dati di esecuzioni precedenti
    rm -rf "$monitor_dir/consumer" "$monitor_dir/provider"

    echo "Avvio monitoraggio cluster..."

    MONITOR_INTERVAL="$MONITOR_INTERVAL" \
    OUTPUT_DIR="$monitor_dir" \
        bash "$MONITOR_SCRIPT" &

    MONITOR_PID=$!

    echo "Monitor PID: $MONITOR_PID"
    echo "Output: $monitor_dir"
}

stop_monitor() {
    if [[ -n "$MONITOR_PID" ]]; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        MONITOR_PID=""
    fi
}

# =====================================
# CLEANUP
# =====================================

cleanup() {
    local status=$?

    trap - EXIT INT TERM

    echo ""
    echo "Pulizia risorse..."

    stop_monitor

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

trap cleanup EXIT
trap 'exit 130' INT TERM

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

docker inspect "$FAULT_NODE" >/dev/null

if [[ "$(docker inspect -f '{{.State.Running}}' "$FAULT_NODE")" != "true" ]]; then
    echo "Errore: worker $FAULT_NODE non in esecuzione"
    exit 1
fi

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
# LOADGENERATOR
# =====================================

create_loadgen_pod() {
    echo "Creo loadgenerator $LOADGEN_POD..."

    consumer delete pod "$LOADGEN_POD" \
        -n "$NAMESPACE" \
        --ignore-not-found \
        --wait=true

    consumer run "$LOADGEN_POD" \
        -n "$NAMESPACE" \
        --image="$LOADGEN_IMAGE" \
        --image-pull-policy=IfNotPresent \
        --restart=Never \
        --overrides="$(printf \
        '{"spec":{"nodeSelector":{"kubernetes.io/hostname":"%s"},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}' \
        "$LOADGEN_NODE")" \
        --command -- sleep infinity

    POD_CREATED=1

    consumer wait \
        --for=condition=Ready \
        "pod/$LOADGEN_POD" \
        -n "$NAMESPACE" \
        --timeout=180s

    consumer exec -n "$NAMESPACE" "$LOADGEN_POD" \
        -- locust --version

    echo "Carico locustfile..."

    consumer exec -i -n "$NAMESPACE" "$LOADGEN_POD" \
        -- sh -c "cat > $LOCUSTFILE" \
        < "$LOCUSTFILE_LOCAL"
}

# =====================================
# ESECUZIONE LOCUST
# =====================================

run_locust() {
    local users="$1"
    local duration="$2"
    local csv_prefix="$3"

    local spawn=$(( (users + RAMP_S - 1) / RAMP_S ))

    consumer exec -n "$NAMESPACE" "$LOADGEN_POD" -- \
        locust \
        -f "$LOCUSTFILE" \
        --host="$TARGET_URL" \
        --headless \
        -u "$users" \
        -r "$spawn" \
        --run-time "${duration}s" \
        --csv="$csv_prefix" \
        --csv-full-history \
        --exit-code-on-error 0
}

# =====================================
# RACCOLTA CSV LOCUST
# =====================================

collect_csv() {
    local kind src dest

    for kind in stats failures stats_history; do
        src="/tmp/fault_${kind}.csv"
        dest="$RAW_DIR/${PREFIX}_${kind}.csv"

        if ! consumer exec -n "$NAMESPACE" "$LOADGEN_POD" \
            -- cat "$src" > "$dest" 2>/dev/null; then

            rm -f "$dest"
            echo "Attenzione: CSV $kind non disponibile"
        fi
    done
}

# =====================================
# PREPARAZIONE LOADGENERATOR
# =====================================

if [[ -z "$LOADGEN_IMAGE" ]]; then
    LOADGEN_IMAGE="$(consumer get deploy "$LOADGEN_DEPLOY" \
        -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')"
fi

[[ -n "$LOADGEN_IMAGE" ]] || {
    echo "Errore: immagine loadgenerator non trovata"
    exit 1
}

echo "Spengo deployment $LOADGEN_DEPLOY..."

consumer scale deploy "$LOADGEN_DEPLOY" \
    -n "$NAMESPACE" \
    --replicas=0

consumer wait \
    --for=delete pod \
    -l "app=$LOADGEN_DEPLOY" \
    -n "$NAMESPACE" \
    --timeout=90s || true

# =====================================
# INIZIO ESPERIMENTO
# =====================================

echo ""
echo "================================="
echo "FAULT TEST LIQO"
echo "================================="
echo "Utenti: $USERS"
echo "Run: $RUNS"
echo "Worker provider: $FAULT_NODE"
echo "Guasto dopo: ${FAULT_AT}s"
echo "Osservazione guasto: ${FAULT_OBSERVE}s"
echo "Osservazione recovery: ${RECOVERY_OBSERVE}s"
echo "Durata Locust: ${TOTAL_TIME}s"
echo "Monitoraggio: ${MONITOR_INTERVAL}s"
echo "Output: $OUTPUT_DIR"
echo "================================="

for ((RUN=1; RUN<=RUNS; RUN++)); do

    PREFIX="U${USERS}_run${RUN}"
    FAULT_EVENTS="$RAW_DIR/${PREFIX}_fault_events.csv"

    echo "timestamp,event" > "$FAULT_EVENTS"

    echo ""
    echo "================================="
    echo "RUN $RUN / $RUNS"
    echo "================================="

    # ---------------------------------
    # VERIFICHE INIZIALI
    # ---------------------------------

    check_provider_ready || {
        echo "Errore: worker provider non Ready"
        exit 1
    }

    check_app_ready || {
        echo "Errore: applicazione non disponibile"
        exit 1
    }

    provider get pods -A -o wide \
        > "$RAW_DIR/${PREFIX}_provider_pods_before.txt"

    consumer get pods -n "$NAMESPACE" -o wide \
        > "$RAW_DIR/${PREFIX}_consumer_pods_before.txt"

    # ---------------------------------
    # LOADGENERATOR E WARM-UP
    # ---------------------------------

    create_loadgen_pod

    log_event "WARMUP_START"

    run_locust \
        "$WARMUP_USERS" \
        "$WARMUP_DURATION" \
        /tmp/warmup \
        > "$RAW_DIR/${PREFIX}_warmup.log" 2>&1

    log_event "WARMUP_END"

    # ---------------------------------
    # AVVIO MONITORAGGIO ESTERNO
    # ---------------------------------

    start_monitor

    # ---------------------------------
    # AVVIO LOCUST
    # ---------------------------------

    echo "Avvio Locust con $USERS utenti..."

    RUN_START_TS=$(date +%s)
    log_event "LOCUST_START"

    run_locust \
        "$USERS" \
        "$TOTAL_TIME" \
        /tmp/fault \
        > "$RAW_DIR/${PREFIX}.txt" 2>&1 &

    LOCUST_PID=$!

    # ---------------------------------
    # FASE 1 - FUNZIONAMENTO NORMALE
    # ---------------------------------

    echo "Attendo ${FAULT_AT}s prima del guasto..."
    sleep "$FAULT_AT"

    # ---------------------------------
    # FASE 2 - GUASTO WORKER
    # ---------------------------------

    echo ""
    echo "GUASTO: $FAULT_NODE"

    log_event "FAULT_COMMAND_START"

    NODE_STOPPED=1

    docker stop --time 10 "$FAULT_NODE" >/dev/null

    log_event "NODE_STOPPED"

    echo "Worker arrestato."
    echo "Osservazione per ${FAULT_OBSERVE}s..."

    sleep "$FAULT_OBSERVE"

    # ---------------------------------
    # FASE 3 - RIAVVIO WORKER
    # ---------------------------------

    echo ""
    echo "RIPRISTINO WORKER"

    log_event "NODE_RESTART_COMMAND"

    docker start "$FAULT_NODE" >/dev/null

    NODE_STOPPED=0

    log_event "NODE_RESTARTED"

    echo "Osservazione recovery per ${RECOVERY_OBSERVE}s..."
    sleep "$RECOVERY_OBSERVE"

    log_event "RECOVERY_OBSERVATION_END"

    # ---------------------------------
    # COMPLETAMENTO LOCUST
    # ---------------------------------

    set +e
    wait "$LOCUST_PID"
    LOCUST_STATUS=$?
    set -e

    LOCUST_PID=""

    RUN_END_TS=$(date +%s)

    log_event "LOCUST_END"

    # ---------------------------------
    # TIMESTAMP PROMETHEUS
    # ---------------------------------

    cat > "$RAW_DIR/run${RUN}_times.txt" <<EOF
start=$RUN_START_TS
end=$RUN_END_TS
ramp_s=$RAMP_S
EOF

    echo "Locust exit status: $LOCUST_STATUS" \
        > "$RAW_DIR/${PREFIX}_status.txt"

    # ---------------------------------
    # RACCOLTA RISULTATI
    # ---------------------------------

    collect_csv

    provider get pods -A -o wide \
        > "$RAW_DIR/${PREFIX}_provider_pods_after.txt" || true

    consumer get pods -n "$NAMESPACE" -o wide \
        > "$RAW_DIR/${PREFIX}_consumer_pods_after.txt" || true

    stop_monitor

    # ---------------------------------
    # ELIMINAZIONE LOADGENERATOR
    # ---------------------------------

    consumer delete pod "$LOADGEN_POD" \
        -n "$NAMESPACE" \
        --ignore-not-found \
        --wait=true

    POD_CREATED=0

    # ---------------------------------
    # VERIFICA RIPRISTINO
    # ---------------------------------

    echo "Verifico ripristino cluster..."

    check_provider_ready || {
        echo "Errore: worker provider non recuperato"
        exit 1
    }

    check_app_ready || {
        echo "Errore: applicazione non recuperata"
        exit 1
    }

    echo "Run completata: $PREFIX"

    if (( RUN < RUNS )); then
        echo "Cooldown: ${COOLDOWN}s..."
        sleep "$COOLDOWN"
    fi
done

echo ""
echo "================================="
echo "FAULT TEST COMPLETATO"
echo "Output: $OUTPUT_DIR"
echo "================================="