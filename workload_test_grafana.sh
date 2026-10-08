#!/bin/bash

set -e

# =========================
# CARICAMENTO CONFIG
# =========================

source workload_exp_config.conf

if [ -z "$TEST" ] || [ -z "$CONNECTIONS" ]; then
    echo "Errore: configurazione esperimento incompleta"
    exit 1
fi

# =========================
# CONFIGURAZIONE
# =========================

export KUBECONFIG="$(pwd)/consumer-config"

GRAFANA_PID=""

# OUTPUT_DIR="experiments/baseline/workload_test/c${CONNECTIONS}/raw"
OUTPUT_DIR="experiments/${TEST}/workload_test/c${CONNECTIONS}/raw"

RESULT_FILE="wrk_t${THREADS}_c${CONNECTIONS}.txt"

mkdir -p "$OUTPUT_DIR"

# ====================================
# GESTIONE INTERRUZIONE E TERMINAZIONE
# ====================================

cleanup() {
    echo ""
    echo "================================="
    echo "Pulizia risorse..."
    echo "================================="

    # Chiude eventuale port-forward Grafana
    if [ -n "$GRAFANA_PID" ]; then
        kill "$GRAFANA_PID" 2>/dev/null || true
        wait "$GRAFANA_PID" 2>/dev/null || true
    fi

    # Elimina pod wrk
    kubectl delete pod \
        "$WRK_POD" \
        -n "$NAMESPACE" \
        --ignore-not-found || true

    echo "Pulizia completata."
}

trap cleanup EXIT
trap 'exit 130' SIGINT SIGTERM

echo "================================="
echo "START TEST"
echo "================================="

echo "Kubeconfig:"
echo "$KUBECONFIG"

# =========================
# PASSWORD GRAFANA
# =========================

echo ""
echo "Recupero password Grafana..."

GRAFANA_PASSWORD=$(kubectl get secret \
-n $MONITORING_NAMESPACE monitoring-grafana \
-o jsonpath="{.data.admin-password}" | base64 -d)

echo "Password Grafana:"
echo "$GRAFANA_PASSWORD"

# =========================
# PORT FORWARD GRAFANA
# =========================

echo ""
echo "Avvio port-forward Grafana..."

nohup kubectl port-forward \
-n $MONITORING_NAMESPACE \
svc/monitoring-grafana \
3000:80 \
> /tmp/grafana-portforward.log 2>&1 &

GRAFANA_PID=$!

echo "Grafana PID: $GRAFANA_PID"

sleep 5

echo "Grafana disponibile:"
echo "http://localhost:3000"

# =========================
# CREAZIONE POD WRK
# =========================

echo ""
echo "Creo pod wrk..."

kubectl delete pod $WRK_POD \
-n $NAMESPACE \
--ignore-not-found


kubectl run $WRK_POD \
-n $NAMESPACE \
--image=alpine \
--restart=Never \
--overrides='
{
  "spec": {
    "nodeSelector": {
      "kubernetes.io/hostname": "consumer-worker"
    }
  }
}' \
--command -- sleep 3600

echo "Attendo pod Ready..."

kubectl wait \
--for=condition=Ready \
pod/$WRK_POD \
-n $NAMESPACE \
--timeout=60s

echo ""
echo "Nodo dove è stato schedulato wrk-tester:"
kubectl get pod $WRK_POD -n $NAMESPACE -o wide

# =========================
# INSTALLAZIONE WRK
# =========================

echo ""
echo "Installazione wrk..."

kubectl exec \
-n $NAMESPACE \
$WRK_POD -- \
apk add --no-cache wrk

# =========================
# ESECUZIONE TEST
# =========================

for RUN in $(seq 1 $RUNS)
do
    echo ""
    echo "================================="
    echo "RUN $RUN / $RUNS"
    echo "================================="

    RESULT_FILE="wrk_t${THREADS}_c${CONNECTIONS}_run${RUN}.txt"

    echo "Avvio WRK..."
    RUN_START_TS=$(date +%s)
    kubectl exec \
    -n $NAMESPACE \
    $WRK_POD -- sh -c "
    {
        echo 'Test: ${TEST}'
        echo 'Configuration: t${THREADS} c${CONNECTIONS} d${DURATION}'
        echo 'Run: ${RUN}'
        date

        wrk \
        -t${THREADS} \
        -c${CONNECTIONS} \
        -d${DURATION} \
        --latency \
        ${TARGET_URL}

    } > /tmp/${RESULT_FILE}
    "
    RUN_END_TS=$(date +%s)
    echo "start=$RUN_START_TS" > "$OUTPUT_DIR/run${RUN}_times.txt"
    echo "end=$RUN_END_TS" >> "$OUTPUT_DIR/run${RUN}_times.txt"
    
    echo "Copio risultato..."

    kubectl cp \
    -n $NAMESPACE \
    $WRK_POD:/tmp/$RESULT_FILE \
    $OUTPUT_DIR/$RESULT_FILE

    echo "Run ${RUN} completata."

    # Pausa tra una run e l'altra
    if [ "$RUN" -lt "$RUNS" ]; then
        echo "Cooldown di $COOLDOWN secondi prima della prossima run..."
        sleep $COOLDOWN
    fi
done

echo ""
echo "================================="
echo "TEST COMPLETATO"
echo "Risultato:"
echo "$OUTPUT_DIR/$RESULT_FILE"
echo "================================="
echo ""
echo "Aspetto 180 secondi per chiudere port-forward Grafana e pulire risorse..."
sleep 180
