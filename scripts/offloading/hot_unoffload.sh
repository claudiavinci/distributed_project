
#!/usr/bin/env bash

# Test di rientro pianificato dei workload Liqo.
# Locust rimane attivo durante tutta la migrazione.

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

for v in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!v:-}" ]]; then
        echo "Errore: variabile mancante: $v"
        exit 1
    fi
done

USERS="$USERS_LIST"

RETURN_AT=120
RETURN_OBSERVE=600
POST_RETURN_OBSERVE=120

MONITOR_INTERVAL=10
READY_TIMEOUT=300
POLL_INTERVAL=2

TOTAL_TIME=$((RETURN_AT + RETURN_OBSERVE + POST_RETURN_OBSERVE + 45))

read -r -a DEPLOY_LIST <<< "$DEPLOYMENTS_LIST"
OFFLOADED_LIST=()

CONSUMER_CONFIG="$KUBECONFIG"
PROVIDER_CONFIG="$REMOTE_KUBECONFIG"

LOADGEN_DEPLOY="loadgenerator"
LOADGEN_IMAGE=""
LOCUSTFILE="/tmp/locustfile.py"

MONITOR_SCRIPT="scripts/fault_test/monitor_fault.sh"

OUTPUT_DIR="$(pwd)/results/${TEST}/load_test/U${USERS}"
RAW_DIR="$OUTPUT_DIR/raw"

mkdir -p "$RAW_DIR" "$OUTPUT_DIR/metrics_csv"

# =====================================
# STATO
# =====================================

POD_CREATED=0
LOCUST_PID=""
MONITOR_PID=""
PREFIX=""
RETURN_EVENTS=""

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

epoch_ms() {
    date +%s%3N
}

log_event() {
    printf '%s,%s\n' "$(timestamp)" "$1" |
        tee -a "$RETURN_EVENTS"
}

# =====================================
# MONITORAGGIO
# =====================================

start_monitor() {
    local monitor_dir="$OUTPUT_DIR/return_monitor/run1"
    mkdir -p "$monitor_dir"
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

for cmd in kubectl liqoctl; do
    command -v "$cmd" >/dev/null || {
        echo "Errore: comando non disponibile: $cmd"
        exit 1
    }
done

# =====================================
# VERIFICA APPLICAZIONE
# =====================================

check_app_ready() {
    local deadline=$((SECONDS + READY_TIMEOUT))
    local deployments deployment all_ready found 
    echo "Verifico disponibilità applicazione..."
    while (( SECONDS < deadline )); do
        deployments="$(consumer get deployments \
            -n "$NAMESPACE" \
            -o jsonpath='{.items[*].metadata.name}' \
            --request-timeout=5s)" || {
            sleep 5
            continue
        }
        [[ -n "$deployments" ]] || {
            sleep 5
            continue
        }
        all_ready=1
        found=0
        for deployment in $deployments; do
            [[ "$deployment" == "$LOADGEN_DEPLOY" ]] && continue
            found=1
            if ! consumer rollout status \
                "deployment/$deployment" \
                -n "$NAMESPACE" \
                --timeout=2s >/dev/null 2>&1; then
                all_ready=0
                break
            fi
        done

        if (( all_ready && found )); then
            return 0
        fi
        sleep 5
    done
    return 1
}

# =====================================
# RILEVAMENTO WORKLOAD OFFLOADATI
# =====================================

# Identifica i Deployment effettivamente sul
# VirtualNode, ignorando i Pod falliti.

detect_offloaded() {
    local deployment nodes node type
    OFFLOADED_LIST=()

    for deployment in "${DEPLOY_LIST[@]}"; do

        nodes="$(consumer get pods \
            -n "$NAMESPACE" \
            -l "app=$deployment" \
            --field-selector=status.phase!=Failed \
            -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
            --request-timeout=5s)" || return 1

        [[ -n "$nodes" ]] || {
            echo "Errore: nessun Pod attivo per $deployment"
            return 1
        }

        while read -r node; do

            [[ -n "$node" ]] || continue

            type="$(consumer get node "$node" \
                -o jsonpath='{.metadata.labels.liqo\.io/type}' \
                --request-timeout=5s)" || return 1

            if [[ "$type" == "virtual-node" ]]; then
                OFFLOADED_LIST+=("$deployment")
                break
            fi
        done <<< "$nodes"
    done

    if (( ${#OFFLOADED_LIST[@]} == 0 )); then
        echo "Errore: nessun Deployment risulta offloadato"
        return 1
    fi
    echo "Deployment offloadati: ${OFFLOADED_LIST[*]}"
}

# =====================================
# VERIFICA POSIZIONAMENTO WORKLOAD
# =====================================

# Per ogni Deployment offloadato verifica
# la presenza di un Pod Ready sul nodo atteso.
# Ignora i vecchi Pod OffloadingAborted.

check_placement() {
    local expected="$1"
    local deployment pods node ready type found

    for deployment in "${OFFLOADED_LIST[@]}"; do

        pods="$(consumer get pods \
            -n "$NAMESPACE" \
            -l "app=$deployment" \
            --field-selector=status.phase!=Failed \
            -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
            --request-timeout=5s)" || return 1

        found=0

        while read -r node ready; do

            [[ -n "$node" && "$ready" == "True" ]] || continue

            type="$(consumer get node "$node" \
                -o jsonpath='{.metadata.labels.liqo\.io/type}' \
                --request-timeout=5s)" || return 1

            if [[ "$expected" == "remote" ]]; then
                if [[ "$type" == "virtual-node" ]]; then
                    found=1
                    break
                fi
            else
                if [[ "$type" != "virtual-node" ]]; then
                    found=1
                    break
                fi
            fi

        done <<< "$pods"
        [[ "$found" -eq 1 ]] || return 1
    done

    return 0
}

# =====================================
# ATTESA RIENTRO
# =====================================

wait_for_return() {
    local deadline=$((SECONDS + RETURN_OBSERVE))
    echo "Attendo il rientro dei workload..."
    while (( SECONDS < deadline )); do
        if check_placement "local"; then
            log_event "WORKLOADS_LOCAL_READY"
            return 0
        fi
        sleep "$POLL_INTERVAL"
    done
    log_event "RETURN_TIMEOUT"
    return 1
}

# =====================================
# PULIZIA SHADOW POD LIQO
# =====================================

# Elimina soltanto gli shadow Pod falliti.
# Non influisce sulla misura del rientro.

cleanup_shadow_pods() {
    echo "Pulizia shadow Pod Liqo falliti..."

    consumer delete pods \
        -n "$NAMESPACE" \
        -l "liqo.io/shadowPod=true" \
        --field-selector=status.phase=Failed \
        --ignore-not-found \
        --wait=false
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
        src="/tmp/return_${kind}.csv"
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

LOADGEN_IMAGE="$(consumer get deploy "$LOADGEN_DEPLOY" \
    -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"

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
echo "LIQO WORKLOAD RETURN TEST"
echo "================================="
echo "Utenti: $USERS"
echo "Deployment eleggibili: ${DEPLOY_LIST[*]}"
echo "Rientro dopo: ${RETURN_AT}s"
echo "Osservazione rientro: ${RETURN_OBSERVE}s"
echo "Osservazione finale: ${POST_RETURN_OBSERVE}s"
echo "Durata Locust: ${TOTAL_TIME}s"
echo "Output: $OUTPUT_DIR"
echo "================================="

PREFIX="U${USERS}_run1"
RETURN_EVENTS="$RAW_DIR/${PREFIX}_return_events.csv"

echo "timestamp,event" > "$RETURN_EVENTS"

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

check_placement "remote" || {
    echo "Errore: workload offloadati non Ready sul VirtualNode"
    exit 1
}

provider get pods -A -o wide \
    > "$RAW_DIR/${PREFIX}_provider_pods_before.txt"

consumer get pods -n "$NAMESPACE" -o wide \
    > "$RAW_DIR/${PREFIX}_consumer_pods_before.txt"

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

echo "Avvio Locust con $USERS utenti..."

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

log_event "OFFLOADING_DISABLED"

# =====================================
# FASE 3 - ATTESA RIENTRO
# =====================================

RETURN_OK=0

if wait_for_return; then
    RETURN_OK=1

    END_MS=$(epoch_ms)
    DURATION_MS=$((END_MS - START_MS))

    echo "return_duration_ms=$DURATION_MS" \
        > "$RAW_DIR/${PREFIX}_return_duration.txt"

    echo "Rientro completato in $DURATION_MS ms"
else
    echo "Attenzione: rientro non completato"
fi

# =====================================
# FASE 4 - OSSERVAZIONE FINALE
# =====================================

echo "Osservazione finale..."

ELAPSED=$(( $(date +%s) - RUN_START_TS ))
REMAINING=$(( TOTAL_TIME - ELAPSED ))

if (( REMAINING > 0 )); then
    sleep "$REMAINING"
fi

log_event "POST_RETURN_OBSERVATION_END"

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

cat > "$RAW_DIR/run1_times.txt" <<EOF_TIMES
start=$RUN_START_TS
end=$RUN_END_TS
ramp_s=$RAMP_S
EOF_TIMES

echo "Locust exit status: $LOCUST_STATUS" \
    > "$RAW_DIR/${PREFIX}_status.txt"

# =====================================
# RACCOLTA RISULTATI
# =====================================

collect_csv

provider get pods -A -o wide \
    > "$RAW_DIR/${PREFIX}_provider_pods_after.txt" || true

consumer get pods -n "$NAMESPACE" -o wide \
    > "$RAW_DIR/${PREFIX}_consumer_pods_after.txt" || true

consumer get events -n "$NAMESPACE" \
    --sort-by=.lastTimestamp \
    > "$RAW_DIR/${PREFIX}_events.txt" || true

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
# VERIFICA FINALE
# =====================================

check_app_ready || {
    echo "Errore: applicazione non disponibile"
    exit 1
}

if (( RETURN_OK == 0 )); then
    echo "Test concluso, ma rientro non completato."
    exit 1
fi

# Pulizia dopo la misurazione e la raccolta dati.
cleanup_shadow_pods

echo ""
echo "================================="
echo "WORKLOAD RETURN TEST COMPLETATO"
echo "Output: $OUTPUT_DIR"
echo "================================="