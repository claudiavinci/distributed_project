
#!/usr/bin/env bash

# =====================================================
# FAULT TEST - GUASTO WORKER PROVIDER LIQO
#
# Test con 400 utenti e 3 ripetizioni.
#
# Per ogni run:
# 1. Verifica lo stato iniziale dei cluster
# 2. Crea un nuovo loadgenerator sul consumer
# 3. Esegue il warm-up
# 4. Avvia Locust con 400 utenti
# 5. Arresta un worker del provider
# 6. Osserva il recupero con il worker spento
# 7. Riavvia il worker
# 8. Raccoglie metriche e verifica il ripristino
#
# Il guasto interessa un worker, non l'intero provider.
# =====================================================

set -Eeuo pipefail

# =====================================
# CARICAMENTO CONFIGURAZIONE
# =====================================

source configs/exp_config.conf

REQUIRED_VARS=(
    TEST
    NAMESPACE
    LOADGEN_POD
    LOADGEN_NODE
    TARGET_URL
    RAMP_S
    WARMUP_USERS
    WARMUP_DURATION
    LOCUSTFILE_LOCAL
)

for v in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!v:-}" ]]; then
        echo "Errore: variabile mancante: $v"
        exit 1
    fi
done

# =====================================
# CONFIGURAZIONE ESPERIMENTO
# =====================================

USERS=400
RUNS=3

# Il guasto viene iniettato dopo 120 secondi
# dall'avvio del comando Locust.
FAULT_AT=120
# Tempo di osservazione con il worker spento
FAULT_OBSERVE=300
# Tempo di osservazione dopo il riavvio
RECOVERY_OBSERVE=120
TOTAL_TIME=$((FAULT_AT + FAULT_OBSERVE + RECOVERY_OBSERVE))
MONITOR_INTERVAL=5
READY_TIMEOUT=300
COOLDOWN="${COOLDOWN:-30}"

# =====================================
# CONFIGURAZIONE KUBERNETES
# =====================================

CONSUMER_KUBECONFIG="$(pwd)/consumer-config"
# Modificare se il kubeconfig ha un nome diverso
PROVIDER_KUBECONFIG="${PROVIDER_KUBECONFIG:-$(pwd)/provider-config}"
# Worker Kind da arrestare
REMOTE_NODE="${REMOTE_NODE:-patient-cloud-worker}"

export KUBECONFIG="$CONSUMER_KUBECONFIG"

# =====================================
# CONFIGURAZIONE LOADGENERATOR
# =====================================

LOADGEN_DEPLOY="${LOADGEN_DEPLOY:-loadgenerator}"
LOADGEN_IMAGE="${LOADGEN_IMAGE:-}"
LOCUSTFILE="/tmp/locustfile.py"

# =====================================
# OUTPUT
# =====================================

BASE_OUTPUT_DIR="$(pwd)/results/${TEST}"
mkdir -p "$BASE_OUTPUT_DIR"

# =====================================
# VARIABILI DI STATO
# =====================================

NODE_STOPPED=0
POD_CREATED=0

LOCUST_PID=""
MONITOR_PID=""

CURRENT_OUTPUT=""

# =====================================
# FUNZIONI COMUNI
# =====================================

consumer() {
    kubectl --kubeconfig "$CONSUMER_KUBECONFIG" "$@"
}

provider() {
    kubectl --kubeconfig "$PROVIDER_KUBECONFIG" "$@"
}

timestamp() {
    date -u +%Y-%m-%dT%H:%M:%S.%NZ
}

log_event() {
    local event="$1"
    printf '%s,%s\n' "$(timestamp)" "$event" \
        | tee -a "$CURRENT_OUTPUT/events.csv"
}

# =====================================
# CLEANUP
# =====================================

stop_monitor() {
    if [[ -n "$MONITOR_PID" ]]; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        MONITOR_PID=""
    fi
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    echo ""
    echo "Pulizia risorse..."
    stop_monitor
    # Ripristino di emergenza del worker
    if (( NODE_STOPPED )); then
        echo "Riavvio worker $REMOTE_NODE..."
        docker start "$REMOTE_NODE" >/dev/null || true
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
# VALIDAZIONE
# =====================================

if [[ ! -f "$LOCUSTFILE_LOCAL" ]]; then
    echo "Errore: locustfile non trovato: $LOCUSTFILE_LOCAL"
    exit 1
fi

if [[ ! -f "$CONSUMER_KUBECONFIG" ]]; then
    echo "Errore: kubeconfig consumer non trovato"
    exit 1
fi

if [[ ! -f "$PROVIDER_KUBECONFIG" ]]; then
    echo "Errore: kubeconfig provider non trovato"
    exit 1
fi

for cmd in kubectl docker python3; do
    command -v "$cmd" >/dev/null || {
        echo "Errore: comando non disponibile: $cmd"
        exit 1
    }
done

docker inspect "$REMOTE_NODE" >/dev/null

if [[ "$REMOTE_NODE" != *worker* ]]; then
    echo "Errore: selezionare un worker del provider"
    exit 1
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "$REMOTE_NODE")" != "true" ]]; then
    echo "Errore: worker $REMOTE_NODE non in esecuzione"
    exit 1
fi

# =====================================
# VERIFICA NODO PROVIDER
# =====================================

check_provider_ready() {
    local deadline=$((SECONDS + READY_TIMEOUT))
    echo "Verifico worker $REMOTE_NODE..."
    while (( SECONDS < deadline )); do
        local ready

        ready="$(provider get node "$REMOTE_NODE" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
            2>/dev/null || true)"

        if [[ "$ready" == "True" ]]; then
            return 0
        fi
        sleep 5
    done
    return 1
}

# =====================================
# VERIFICA DEPLOYMENT APPLICATIVI
# =====================================

check_app_ready() {

    local deadline=$((SECONDS + READY_TIMEOUT))
    echo "Verifico disponibilità applicazione..."
    while (( SECONDS < deadline )); do
        if consumer get deploy -n "$NAMESPACE" -o json \
            | python3 -c '
import json
import sys

deployments = json.load(sys.stdin)["items"]
loadgen = sys.argv[1]

deployments = [
    d for d in deployments
    if d["metadata"]["name"] != loadgen
]

ready = all(
    d.get("status", {}).get("availableReplicas", 0)
    >= d["spec"].get("replicas", 1)
    for d in deployments
)

sys.exit(0 if deployments and ready else 1)
' "$LOADGEN_DEPLOY" 2>/dev/null
        then
            return 0
        fi

        sleep 5
    done

    return 1
}

# =====================================
# CREAZIONE LOADGENERATOR
# =====================================

create_loadgen_pod() {

    echo ""
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

    echo "Loadgenerator pronto."
}

# =====================================
# ESECUZIONE LOCUST
# =====================================

run_locust() {

    local users="$1"
    local duration="$2"
    local prefix="$3"
    local spawn=$(( (users + RAMP_S - 1) / RAMP_S ))

    consumer exec -n "$NAMESPACE" "$LOADGEN_POD" -- \
        locust \
        -f "$LOCUSTFILE" \
        --host="$TARGET_URL" \
        --headless \
        -u "$users" \
        -r "$spawn" \
        --run-time "${duration}s" \
        --csv="$prefix" \
        --csv-full-history \
        --exit-code-on-error 0
}

# =====================================
# MONITORAGGIO KUBERNETES
# =====================================

monitor_cluster() {

    while true; do
        {
            echo "================================="
            echo "Timestamp: $(timestamp)"
            echo "================================="

            echo "--- CONSUMER NODES ---"

            consumer get nodes -o wide \
                --request-timeout=5s || true

            echo "--- CONSUMER PODS ---"

            consumer get pods -n "$NAMESPACE" -o wide \
                --request-timeout=5s || true

            echo "--- PROVIDER NODES ---"

            provider get nodes -o wide \
                --request-timeout=5s || true

            echo "--- PROVIDER PODS ---"

            provider get pods -A -o wide \
                --request-timeout=5s || true

        } >> "$CURRENT_OUTPUT/cluster_monitor.log" 2>&1
        sleep "$MONITOR_INTERVAL"
    done
}

# =====================================
# RACCOLTA CSV LOCUST
# =====================================

collect_csv() {
    for KIND in stats failures stats_history; do
        if ! consumer exec -n "$NAMESPACE" "$LOADGEN_POD" \
            -- cat "/tmp/fault_${KIND}.csv" \
            > "$CURRENT_OUTPUT/locust_${KIND}.csv" 2>/dev/null
        then
            rm -f "$CURRENT_OUTPUT/locust_${KIND}.csv"
            echo "Attenzione: CSV $KIND non disponibile"
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

if [[ -z "$LOADGEN_IMAGE" ]]; then
    echo "Errore: immagine loadgenerator non trovata"
    exit 1
fi

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
echo "Worker provider: $REMOTE_NODE"
echo "Guasto dopo: ${FAULT_AT}s"
echo "Osservazione guasto: ${FAULT_OBSERVE}s"
echo "Osservazione ripristino: ${RECOVERY_OBSERVE}s"
echo "Durata run: ${TOTAL_TIME}s"
echo "================================="

for ((RUN=1; RUN<=RUNS; RUN++)); do

    CURRENT_OUTPUT="${BASE_OUTPUT_DIR}/run${RUN}"
    mkdir -p "$CURRENT_OUTPUT"

    echo "timestamp_utc,event" > "$CURRENT_OUTPUT/events.csv"

    echo ""
    echo "================================="
    echo "RUN $RUN / $RUNS"
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

    echo "Salvo collocazione iniziale dei Pod..."

    provider get pods -A -o wide \
        > "$CURRENT_OUTPUT/provider_pods_before.txt"

    consumer get pods -n "$NAMESPACE" -o wide \
        > "$CURRENT_OUTPUT/consumer_pods_before.txt"

    # =====================================
    # CREAZIONE LOADGENERATOR
    # =====================================

    create_loadgen_pod

    # =====================================
    # WARM-UP
    # =====================================

    log_event "WARMUP_START"

    run_locust \
        "$WARMUP_USERS" \
        "$WARMUP_DURATION" \
        /tmp/warmup \
        > "$CURRENT_OUTPUT/warmup.log" 2>&1

    log_event "WARMUP_END"

    # =====================================
    # MONITORAGGIO
    # =====================================

    monitor_cluster &
    MONITOR_PID=$!

    # =====================================
    # AVVIO LOCUST
    # =====================================

    echo "Avvio Locust con $USERS utenti..."

    log_event "LOCUST_START"

    run_locust \
        "$USERS" \
        "$TOTAL_TIME" \
        /tmp/fault \
        > "$CURRENT_OUTPUT/locust.log" 2>&1 &

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
    echo "================================="
    echo "GUASTO: $REMOTE_NODE"
    echo "================================="

    log_event "FAULT_COMMAND_START"

    NODE_STOPPED=1

    docker stop --time 10 "$REMOTE_NODE" >/dev/null
    log_event "NODE_STOPPED"

    echo "Worker arrestato."
    echo "Osservazione per ${FAULT_OBSERVE}s..."

    sleep "$FAULT_OBSERVE"

    # =====================================
    # FASE 3 - RIAVVIO WORKER
    # =====================================

    echo ""
    echo "================================="
    echo "RIPRISTINO WORKER"
    echo "================================="

    log_event "NODE_RESTART_COMMAND"
    docker start "$REMOTE_NODE" >/dev/null

    NODE_STOPPED=0
    log_event "NODE_RESTARTED"

    # =====================================
    # COMPLETAMENTO LOCUST
    # =====================================

    set +e
    wait "$LOCUST_PID"
    LOCUST_STATUS=$?
    set -e

    LOCUST_PID=""

    log_event "LOCUST_END"

    echo "Locust exit status: $LOCUST_STATUS" \
        > "$CURRENT_OUTPUT/run_status.txt"

    # =====================================
    # RACCOLTA RISULTATI
    # =====================================

    collect_csv

    provider get pods -A -o wide \
        > "$CURRENT_OUTPUT/provider_pods_after.txt" || true

    consumer get pods -n "$NAMESPACE" -o wide \
        > "$CURRENT_OUTPUT/consumer_pods_after.txt" || true

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
    # VERIFICA RECUPERO
    # =====================================

    echo "Verifico ripristino del cluster..."

    check_provider_ready || {
        echo "Errore: worker provider non recuperato"
        exit 1
    }

    check_app_ready || {
        echo "Errore: applicazione non recuperata"
        exit 1
    }

    echo "Run completata: $CURRENT_OUTPUT"

    if (( RUN < RUNS )); then
        echo "Cooldown: ${COOLDOWN}s..."
        sleep "$COOLDOWN"
    fi

done

echo ""
echo "================================="
echo "FAULT TEST COMPLETATO"
echo "Output: $BASE_OUTPUT_DIR"
echo "================================="