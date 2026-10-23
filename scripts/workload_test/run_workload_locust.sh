#!/bin/bash
#
# Test di workload con il loadgenerator di Online Boutique (Locust, ciclo chiuso).
# Per ogni livello di utenti esegue RUNS ripetizioni da DURATION, con un pod nuovo a ogni run.
# Il pod gira sul nodo LOADGEN_NODE (control-plane del consumer, fuori dal worker limitato).

set -euo pipefail

# =========================
# CARICAMENTO CONFIG
# =========================

source configs/exp_config.conf

REQUIRED_VARS=(
  TEST DURATION RUNS COOLDOWN
  NAMESPACE MONITORING_NAMESPACE LOADGEN_POD LOADGEN_NODE TARGET_URL
  USERS_LIST RAMP_S WARMUP_USERS WARMUP_DURATION LOCUSTFILE_LOCAL
)

for v in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!v:-}" ]; then
        echo "Errore: variabile mancante in exp_config.conf: $v"
        exit 1
    fi
done

# Opzionali (con default)
LOADGEN_DEPLOY="${LOADGEN_DEPLOY:-loadgenerator}"
LOADGEN_IMAGE="${LOADGEN_IMAGE:-}"
# Percorso del locustfile dentro il pod: il file locale (LOCUSTFILE_LOCAL, es.
# microservices-demo/src/loadgenerator/locustfile.py) viene caricato qui a ogni run.
LOCUSTFILE="/tmp/locustfile.py"

if [ ! -f "$LOCUSTFILE_LOCAL" ]; then
    echo "Errore: LOCUSTFILE_LOCAL non trovato: $LOCUSTFILE_LOCAL"
    exit 1
fi

# =========================
# CONFIGURAZIONE
# =========================

export KUBECONFIG="$(pwd)/consumer-config"

GRAFANA_PID=""
BASE_OUTPUT_DIR="$(pwd)/results/${TEST}/workload_test"
mkdir -p "$BASE_OUTPUT_DIR"

read -r -a USER_LIST <<< "$USERS_LIST"
TOTAL_RUNS=$(( ${#USER_LIST[@]} * RUNS ))
RUN_COUNTER=0

# =========================
# CLEANUP
# =========================

cleanup() {

    echo ""
    echo "================================="
    echo "Pulizia risorse..."
    echo "================================="

    if [ -n "$GRAFANA_PID" ]; then
        echo "Chiusura port-forward Grafana..."
        kill "$GRAFANA_PID" 2>/dev/null || true
        wait "$GRAFANA_PID" 2>/dev/null || true
    fi

    kubectl delete pod "$LOADGEN_POD" \
        -n "$NAMESPACE" \
        --ignore-not-found || true

    echo "Pulizia completata."
    echo "Nota: il deployment ${LOADGEN_DEPLOY} resta a 0 repliche."
}

trap cleanup EXIT
trap 'exit 130' SIGINT SIGTERM

# =========================
# PREPARAZIONE: spegni il loadgenerator del namespace
# =========================

echo "Spengo il deployment ${LOADGEN_DEPLOY} (il carico lo genera solo il pod di test)..."

if [ -z "$LOADGEN_IMAGE" ]; then
    LOADGEN_IMAGE="$(kubectl get deploy "$LOADGEN_DEPLOY" -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')"
fi

if [ -z "$LOADGEN_IMAGE" ]; then
    echo "Errore: impossibile ricavare l'immagine del loadgenerator. Imposta LOADGEN_IMAGE in exp_config.conf"
    exit 1
fi

kubectl scale deploy "$LOADGEN_DEPLOY" -n "$NAMESPACE" --replicas=0
kubectl wait --for=delete pod -l app="$LOADGEN_DEPLOY" -n "$NAMESPACE" --timeout=90s 2>/dev/null || true

echo "================================="
echo "START TEST (Locust, ciclo chiuso)"
echo "Utenti: ${USERS_LIST}"
echo "Run per livello: ${RUNS}"
echo "Durata run: ${DURATION} (rampa ${RAMP_S}s inclusa)"
echo "Immagine: ${LOADGEN_IMAGE}"
echo "Nodo del generatore: ${LOADGEN_NODE}"
echo "Target: ${TARGET_URL}"
echo "================================="

# =========================
# PORT FORWARD GRAFANA
# =========================

echo ""
echo "Avvio port-forward Grafana..."

nohup kubectl port-forward \
    -n "$MONITORING_NAMESPACE" \
    svc/monitoring-grafana \
    3000:80 \
    > /tmp/grafana-portforward.log 2>&1 &

GRAFANA_PID=$!

sleep 5

echo "Grafana disponibile: http://localhost:3000"

# =========================
# FUNZIONI
# =========================

create_loadgen_pod() {

    echo ""
    echo "Creo pod ${LOADGEN_POD}..."

    kubectl delete pod "$LOADGEN_POD" \
        -n "$NAMESPACE" \
        --ignore-not-found

    kubectl run "$LOADGEN_POD" \
        -n "$NAMESPACE" \
        --image="$LOADGEN_IMAGE" \
        --image-pull-policy=IfNotPresent \
        --restart=Never \
        --overrides="
        {
          \"spec\": {
            \"nodeSelector\": {
              \"kubernetes.io/hostname\": \"${LOADGEN_NODE}\"
            },
            \"tolerations\": [
              {
                \"key\": \"node-role.kubernetes.io/control-plane\",
                \"operator\": \"Exists\",
                \"effect\": \"NoSchedule\"
              }
            ]
          }
        }" \
        --command -- sleep infinity

    echo "Attendo pod Ready..."

    kubectl wait \
        --for=condition=Ready \
        pod/"$LOADGEN_POD" \
        -n "$NAMESPACE" \
        --timeout=180s

    if ! kubectl exec -n "$NAMESPACE" "$LOADGEN_POD" -- locust --version; then
        echo "Errore: locust non eseguibile nell'immagine $LOADGEN_IMAGE"
        exit 1
    fi

    echo "Carico il locustfile nel pod: $LOCUSTFILE_LOCAL"
    kubectl exec -i -n "$NAMESPACE" "$LOADGEN_POD" -- \
        sh -c "cat > ${LOCUSTFILE}" < "$LOCUSTFILE_LOCAL"

    if ! kubectl exec -n "$NAMESPACE" "$LOADGEN_POD" -- test -f "$LOCUSTFILE"; then
        echo "Errore: locustfile non trovato nel pod: $LOCUSTFILE"
        echo "Controlla il percorso con: kubectl exec -n $NAMESPACE $LOADGEN_POD -- find / -name 'locustfile*.py' 2>/dev/null"
        exit 1
    fi

    # Controllo di raggiungibilità del frontend (solo avviso: dipende da python3 nell'immagine)
    if ! kubectl exec -n "$NAMESPACE" "$LOADGEN_POD" -- \
        python3 -c "import urllib.request,sys; urllib.request.urlopen('${TARGET_URL}', timeout=10); print('frontend raggiungibile')"; then
        echo "ATTENZIONE: controllo di raggiungibilità non riuscito (frontend irraggiungibile o python3 assente)."
    fi

    echo ""
    echo "Nodo del generatore:"
    kubectl get pod "$LOADGEN_POD" -n "$NAMESPACE" -o wide
}

# uso: run_locust <utenti> <durata>
# I file CSV vengono scritti nel pod come /tmp/res_*.csv
# --reset-stats azzera le statistiche a rampa finita; --exit-code-on-error 0 evita che
# le richieste fallite (attese in saturazione) facciano abortire lo script.
run_locust() {
    local users="$1"
    local dur="$2"
    local spawn=$(( (users + RAMP_S - 1) / RAMP_S ))

    kubectl exec -n "$NAMESPACE" "$LOADGEN_POD" -- \
        locust -f "$LOCUSTFILE" \
        --host="$TARGET_URL" \
        --headless \
        -u "$users" \
        -r "$spawn" \
        --run-time "$dur" \
        --reset-stats \
        --csv=/tmp/res \
        --exit-code-on-error 0
}

# =========================
# ESECUZIONE: per ogni livello di utenti, RUNS ripetizioni (pod nuovo a ogni run)
# =========================

for USERS in "${USER_LIST[@]}"
do

    OUTPUT_DIR="${BASE_OUTPUT_DIR}/U${USERS}/raw"
    mkdir -p "$OUTPUT_DIR"

    for RUN in $(seq 1 "$RUNS")
    do

        echo ""
        echo "================================="
        echo "UTENTI ${USERS} - RUN ${RUN} / ${RUNS}"
        echo "================================="

        create_loadgen_pod

        # Warm-up del sistema sotto test (non entra nei timestamp della run)
        echo ""
        echo "Warm-up: ${WARMUP_USERS} utenti per ${WARMUP_DURATION}..."

        WARMUP_LOG="$OUTPUT_DIR/U${USERS}_run${RUN}_warmup.log"

        if ! run_locust "$WARMUP_USERS" "$WARMUP_DURATION" > "$WARMUP_LOG" 2>&1; then
            echo "Errore nel warm-up. Ultime righe del log:"
            tail -n 20 "$WARMUP_LOG"
            exit 1
        fi

        RESULT_FILE="U${USERS}_run${RUN}.txt"

        echo ""
        echo "Avvio misura..."

        RUN_START_TS=$(date +%s)

        {
            echo "Test: ${TEST}"
            echo "Configuration: locust closed-loop U${USERS} d${DURATION} ramp ${RAMP_S}s"
            echo "Run: ${RUN}"
            date
            echo ""

            run_locust "$USERS" "$DURATION" 2>&1
        } > "$OUTPUT_DIR/$RESULT_FILE"

        RUN_END_TS=$(date +%s)

        {
            echo "start=$RUN_START_TS"
            echo "end=$RUN_END_TS"
            echo "ramp_s=$RAMP_S"
        } > "$OUTPUT_DIR/run${RUN}_times.txt"

        # CSV di Locust (comodi per l'analisi)
        for KIND in stats failures stats_history
        do
            kubectl exec -n "$NAMESPACE" "$LOADGEN_POD" -- cat "/tmp/res_${KIND}.csv" \
                > "$OUTPUT_DIR/U${USERS}_run${RUN}_${KIND}.csv" \
                || echo "Attenzione: res_${KIND}.csv non recuperato"
        done

        echo "Run completata. Utenti: ${USERS}"
        grep -E "Aggregated" "$OUTPUT_DIR/$RESULT_FILE" || true

        # Se il generatore satura la sua CPU, le latenze misurate non sono affidabili
        if grep -q "CPU usage" "$OUTPUT_DIR/$RESULT_FILE"; then
            echo "ATTENZIONE: Locust segnala CPU alta nel generatore. Il carico potrebbe essere limitato dal generatore."
        fi

        echo ""
        echo "Elimino pod ${LOADGEN_POD}..."

        kubectl delete pod "$LOADGEN_POD" \
            -n "$NAMESPACE" \
            --ignore-not-found

        RUN_COUNTER=$((RUN_COUNTER + 1))

        if [ "$RUN_COUNTER" -lt "$TOTAL_RUNS" ]; then
            echo "Attendo ${COOLDOWN} secondi prima della prossima run..."
            sleep "$COOLDOWN"
        fi
    done
done

echo ""
echo "================================="
echo "TEST COMPLETATO"
echo "Output:"
echo "$BASE_OUTPUT_DIR"
echo "================================="