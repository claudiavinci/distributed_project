#!/bin/bash

set -e

# =========================
# CONFIGURAZIONE ESPERIMENTO
# =========================

TEST_NAME="baseline"

NAMESPACE="shop"
POD_NAME="wrk-tester"

THREADS=16
DURATION="5m"

# Configurazioni wrk
CONNECTIONS_LIST=(25 50 100)

# Numero ripetizioni
RUNS=3

BASE_DIR="experiments/${TEST_NAME}/workload_test"

mkdir -p "$BASE_DIR"

echo "================================="
echo "START WRK EXPERIMENT"
echo "================================="
echo "Test: $TEST_NAME"
echo "Namespace: $NAMESPACE"
echo "Threads: $THREADS"
echo "Duration: $DURATION"
echo "Configurations: ${CONNECTIONS_LIST[*]}"
echo "Runs per configuration: $RUNS"
echo "================================="

# =========================
# CREAZIONE POD WRK
# =========================

echo ""
echo "Creo pod wrk..."

kubectl delete pod $POD_NAME \
    -n $NAMESPACE \
    --ignore-not-found

kubectl run $POD_NAME \
    -n $NAMESPACE \
    --image=alpine \
    --restart=Never \
    --command -- sleep 3600

echo "Attendo che il pod sia Ready..."

kubectl wait \
    --for=condition=Ready \
    pod/$POD_NAME \
    -n $NAMESPACE \
    --timeout=60s

# =========================
# INSTALLAZIONE WRK
# =========================

echo ""
echo "Installazione wrk..."

kubectl exec \
    -n $NAMESPACE \
    $POD_NAME -- \
    apk add --no-cache wrk

# =========================
# LOOP CONFIGURAZIONI
# =========================

for CONNECTIONS in "${CONNECTIONS_LIST[@]}"
do

    CONFIG_DIR="${BASE_DIR}/c${CONNECTIONS}/raw"

    mkdir -p "$CONFIG_DIR"

    echo ""
    echo "#################################"
    echo "CONFIGURAZIONE c=$CONNECTIONS"
    echo "#################################"

    # =========================
    # LOOP RUN
    # =========================

    for RUN in $(seq 1 $RUNS)
    do

        echo ""
        echo "---------------------------------"
        echo "RUN $RUN/$RUNS"
        echo "Connections: $CONNECTIONS"
        echo "---------------------------------"

        RESULT_FILE="wrk_c${CONNECTIONS}_run${RUN}.txt"
        TOP_FILE="top_wrk_c${CONNECTIONS}_run${RUN}.txt"

        # =========================
        # START MONITORAGGIO
        # =========================

        echo "Avvio raccolta metriche..."

        (
        while true
        do
            echo "===== $(date) ====="
            kubectl top pods -n $NAMESPACE
            echo ""

            sleep 5

        done

        ) > "$CONFIG_DIR/$TOP_FILE" &

        METRICS_PID=$!

        # =========================
        # ESECUZIONE WRK
        # =========================

        echo "Avvio wrk..."

        kubectl exec \
            -n $NAMESPACE \
            $POD_NAME -- sh -c "
        {
            echo 'Test: $TEST_NAME'
            echo 'Configuration: t$THREADS c$CONNECTIONS d$DURATION'
            echo 'Run: $RUN'
            date

            wrk --latency \
                -t$THREADS \
                -c$CONNECTIONS \
                -d$DURATION \
                http://frontend-external:80

        } > /tmp/$RESULT_FILE
        "

        # =========================
        # STOP MONITORAGGIO
        # =========================

        kill $METRICS_PID || true

        # =========================
        # COPIA RISULTATI
        # =========================

        echo "Copio risultati..."

        kubectl cp \
            -n $NAMESPACE \
            $POD_NAME:/tmp/$RESULT_FILE \
            "$CONFIG_DIR/$RESULT_FILE"

        echo "Run completata: c${CONNECTIONS} run${RUN}"

        sleep 10

    done
done

# =========================
# CLEANUP FINALE
# =========================

echo ""
echo "Elimino pod wrk..."

kubectl delete pod \
    $POD_NAME \
    -n $NAMESPACE

echo ""
echo "================================="
echo "ESPERIMENTO COMPLETATO"
echo "Risultati salvati in:"
echo "$BASE_DIR"
echo "================================="