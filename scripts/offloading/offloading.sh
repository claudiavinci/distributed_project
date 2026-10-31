
#!/bin/bash

# Misura dell'offloading a freddo di servizi stateless.
# SCENARIO=forced: nodeSelector sul VirtualNode
# SCENARIO=free:   placement scelto dallo scheduler

set -euo pipefail

# =====================================
# CONFIG ESPERIMENTO
# =====================================

source configs/exp_config.conf

for v in TEST NAMESPACE SCENARIO BASE_MANIFEST DEPLOYMENTS_LIST; do
    if [ -z "${!v:-}" ]; then
        echo "Errore: variabile mancante: $v"
        exit 1
    fi
done

if [[ "$SCENARIO" != "forced" && "$SCENARIO" != "free" ]]; then
    echo "Errore: SCENARIO deve essere forced o free"
    exit 1
fi

if [ "$SCENARIO" = "forced" ] && [ -z "${MANIFEST:-}" ]; then
    echo "Errore: MANIFEST mancante per lo scenario forced"
    exit 1
fi

read -r -a DEPLOY_LIST <<< "$DEPLOYMENTS_LIST"

FRONTEND_DEPLOYMENT="${FRONTEND_DEPLOYMENT:-frontend}"
AUTO_RESET="${AUTO_RESET:-1}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"

export KUBECONFIG="$(pwd)/consumer-config"

OUTPUT_DIR="results/$TEST"
RESULT_FILE="$OUTPUT_DIR/offloading_time.txt"
mkdir -p "$OUTPUT_DIR"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "======================================"
echo "OFFLOADING A FREDDO"
echo "======================================"
echo "Scenario: $SCENARIO"
echo "Deployments: ${DEPLOY_LIST[*]}"

# =====================================
# PREPARAZIONE (NON MISURATA)
# =====================================

VIRTUAL_NODES=$(kubectl get nodes \
    -l liqo.io/type=virtual-node \
    -o jsonpath='{.items[*].metadata.name}')

if [ -z "$VIRTUAL_NODES" ]; then
    echo "Errore: nessun VirtualNode trovato"
    exit 1
fi

# Eventuale unoffload
if [ -n "$(kubectl get namespaceoffloading -n "$NAMESPACE" -o name)" ]; then
    if [ "$AUTO_RESET" = "1" ]; then
        liqoctl unoffload namespace "$NAMESPACE"

        kubectl wait --for=delete \
            namespaceoffloading/offloading \
            -n "$NAMESPACE" --timeout=120s
    else
        echo "Errore: namespace gia' offloadato"
        exit 1
    fi
fi

# Elimina eventuali pod OffloadingAborted
kubectl get pods -n "$NAMESPACE" --no-headers \
    | awk '$3=="OffloadingAborted"{print $1}' \
    | xargs -r kubectl delete pod -n "$NAMESPACE"

# Ripristina il manifest locale
echo "Applico il manifest locale..."
kubectl apply -f "$BASE_MANIFEST" -n "$NAMESPACE"

# Verifica che i selector forzati siano stati rimossi
for d in "${DEPLOY_LIST[@]}"; do
    SELECTOR=$(kubectl get deployment "$d" -n "$NAMESPACE" -o json |
        jq -r '.spec.template.spec.nodeSelector["liqo.io/type"] // ""')

    if [ "$SELECTOR" = "virtual-node" ]; then
        echo "Errore: $d ha ancora il nodeSelector remoto"
        exit 1
    fi
done

# Ricrea la baseline sul consumer
echo "Preparo la baseline locale..."

for d in "${DEPLOY_LIST[@]}"; do
    kubectl rollout restart deployment/"$d" -n "$NAMESPACE"
done

for d in "${DEPLOY_LIST[@]}"; do
    kubectl rollout status deployment/"$d" \
        -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"

    # Salva i nomi dei pod precedenti all'esperimento
    kubectl get pods -n "$NAMESPACE" -l "app=$d" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        > "$TMP_DIR/$d.before"

    # Verifica che la baseline sia locale e Ready
    kubectl get pods -n "$NAMESPACE" -l "app=$d" -o json |
        jq -e --argjson expected "$(kubectl get deployment "$d" \
            -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')" '
            [.items[] | select(.metadata.deletionTimestamp == null)] as $pods
            | ($pods | length) == $expected
              and all($pods[];
                .spec.nodeName != null
                and (.spec.nodeName | startswith("liqo-") | not)
                and any(.status.conditions[]?;
                    .type == "Ready" and .status == "True"))
        ' >/dev/null
done

# Controllo esplicito dei VirtualNode nella baseline
for d in "${DEPLOY_LIST[@]}"; do
    NODES=$(kubectl get pods -n "$NAMESPACE" -l "app=$d" \
        -o jsonpath='{.items[*].spec.nodeName}')

    for node in $NODES; do
        if [[ " $VIRTUAL_NODES " == *" $node "* ]]; then
            echo "Errore: $d e' ancora sul VirtualNode"
            exit 1
        fi
    done
done

echo "Stato iniziale:"
kubectl get pods -n "$NAMESPACE" -o wide

# =====================================
# MISURAZIONE
# =====================================

START_TS=$(date +%s)

echo ""
echo "Inizio offloading..."

liqoctl offload namespace "$NAMESPACE" \
    --namespace-mapping-strategy EnforceSameName \
    --pod-offloading-strategy LocalAndRemote

kubectl wait --for=jsonpath='{.status.offloadingPhase}'=Ready \
    namespaceoffloading/offloading \
    -n "$NAMESPACE" --timeout=120s

OFFLOAD_READY_TS=$(date +%s)

# =====================================
# NUOVO SCHEDULING
# =====================================

if [ "$SCENARIO" = "forced" ]; then

    echo "Applico il manifest con nodeSelector remoto..."
    kubectl apply -f "$MANIFEST" -n "$NAMESPACE"

    # Verifica che tutti i Deployment selezionati
    # siano effettivamente vincolati al VirtualNode
    for d in "${DEPLOY_LIST[@]}"; do
        SELECTOR=$(kubectl get deployment "$d" -n "$NAMESPACE" -o json |
            jq -r '.spec.template.spec.nodeSelector["liqo.io/type"] // ""')

        if [ "$SELECTOR" != "virtual-node" ]; then
            echo "Errore: $d non ha il nodeSelector remoto"
            exit 1
        fi
    done

else

    echo "Riavvio i Deployment per lo scheduling libero..."

    for d in "${DEPLOY_LIST[@]}"; do
        kubectl rollout restart deployment/"$d" -n "$NAMESPACE"
    done

fi

# =====================================
# ATTESA ROLLOUT
# =====================================

echo "Attendo i Deployment..."

PIDS=()

for d in "${DEPLOY_LIST[@]}"; do
    (
        kubectl rollout status deployment/"$d" \
            -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT" >/dev/null

        date +%s > "$TMP_DIR/$d.end"
    ) &
    PIDS+=($!)
done

FAILED=0

for pid in "${PIDS[@]}"; do
    wait "$pid" || FAILED=1
done

if [ "$FAILED" -ne 0 ]; then
    echo "Errore: rollout non completato"
    exit 1
fi

# =====================================
# CALCOLO TEMPI
# =====================================

ROLLOUT_END=$START_TS
WORKLOAD_END=$START_TS
REMOTE_END=0

REMOTE_COUNT=0
LOCAL_COUNT=0

PLACEMENT_LINES=""

for d in "${DEPLOY_LIST[@]}"; do

    END=$(cat "$TMP_DIR/$d.end")

    if [ "$END" -gt "$ROLLOUT_END" ]; then
        ROLLOUT_END=$END
    fi

    EXPECTED=$(kubectl get deployment "$d" -n "$NAMESPACE" \
        -o jsonpath='{.spec.replicas}')
    EXPECTED="${EXPECTED:-1}"

    COUNT=0

    # Salva lo stato attuale dei pod
    kubectl get pods -n "$NAMESPACE" -l "app=$d" \
        -o json > "$TMP_DIR/$d.pods.json"

    jq -r '
        .items[]
        | select(.metadata.deletionTimestamp == null)
        | [
            .metadata.name,
            (.spec.nodeName // "NA"),
            ([.status.conditions[]?
              | select(.type == "Ready" and .status == "True")
              | .lastTransitionTime][0] // "NA")
          ]
        | @tsv
    ' "$TMP_DIR/$d.pods.json" > "$TMP_DIR/$d.pods.tsv"

    while IFS=$'\t' read -r POD NODE READY; do

        # Ignora i pod precedenti all'esperimento
        if grep -Fxq "$POD" "$TMP_DIR/$d.before"; then
            continue
        fi

        if [ "$NODE" = "NA" ] || [ "$READY" = "NA" ]; then
            echo "Errore: pod $POD non Ready"
            exit 1
        fi

        COUNT=$((COUNT + 1))
        READY_TS=$(date -u -d "$READY" +%s)

        # Convergenza complessiva
        if [ "$READY_TS" -gt "$WORKLOAD_END" ]; then
            WORKLOAD_END=$READY_TS
        fi

        # Placement e convergenza remota
        if [[ " $VIRTUAL_NODES " == *" $NODE "* ]]; then
            LOCATION="remote"
            REMOTE_COUNT=$((REMOTE_COUNT + 1))

            if [ "$READY_TS" -gt "$REMOTE_END" ]; then
                REMOTE_END=$READY_TS
            fi
        else
            LOCATION="local"
            LOCAL_COUNT=$((LOCAL_COUNT + 1))
        fi

        echo "$d / $POD -> $NODE ($LOCATION)"
        PLACEMENT_LINES+="Placement_${POD}=$NODE:$LOCATION"$'\n'

    done < "$TMP_DIR/$d.pods.tsv"

    if [ "$COUNT" -ne "$EXPECTED" ]; then
        echo "Errore: $d ha $COUNT nuovi pod, attesi $EXPECTED"
        exit 1
    fi

done

# Nello scenario forced tutti i pod devono essere remoti
if [ "$SCENARIO" = "forced" ] && [ "$LOCAL_COUNT" -gt 0 ]; then
    echo "Errore: alcuni pod sono rimasti locali"
    exit 1
fi

WORKLOAD_SECONDS=$((WORKLOAD_END - START_TS))
ROLLOUT_SECONDS=$((ROLLOUT_END - START_TS))
OFFLOAD_READY_SECONDS=$((OFFLOAD_READY_TS - START_TS))

REMOTE_SECONDS="NA"

if [ "$REMOTE_COUNT" -gt 0 ]; then
    REMOTE_SECONDS=$((REMOTE_END - START_TS))
fi

# =====================================
# SALVATAGGIO RISULTATI
# =====================================

{
    echo "Scenario=$SCENARIO"
    echo "Manifest=$([ "$SCENARIO" = forced ] && echo "$MANIFEST" || echo "$BASE_MANIFEST")"
    echo "Deployments=${DEPLOY_LIST[*]}"
    echo "Namespace=$NAMESPACE"
    echo ""
    echo "Start_timestamp=$START_TS"
    echo "End_timestamp=$ROLLOUT_END"
    echo ""
    echo "Remote_convergence_seconds=$REMOTE_SECONDS"
    echo "Workload_convergence_seconds=$WORKLOAD_SECONDS"
    echo "Rollout_observed_seconds=$ROLLOUT_SECONDS"
    echo "Offload_phase_ready_seconds=$OFFLOAD_READY_SECONDS"
    echo ""
    echo "Remote_pods_count=$REMOTE_COUNT"
    echo "Local_pods_count=$LOCAL_COUNT"
    echo ""
    printf "%s" "$PLACEMENT_LINES"

} > "$RESULT_FILE"

echo ""
echo "======================================"
echo "OFFLOADING COMPLETATO"
echo "======================================"
echo "Convergenza remota: $REMOTE_SECONDS s"
echo "Convergenza workload: $WORKLOAD_SECONDS s"
echo "Rollout osservato: $ROLLOUT_SECONDS s"
echo "Pod remoti: $REMOTE_COUNT"
echo "Pod locali: $LOCAL_COUNT"
echo "Risultati: $RESULT_FILE"

# =====================================
# FRONTEND E SNAPSHOT
# =====================================

echo "Riavvio frontend..."

kubectl rollout restart deployment/"$FRONTEND_DEPLOYMENT" \
    -n "$NAMESPACE"

kubectl rollout status deployment/"$FRONTEND_DEPLOYMENT" \
    -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"

sleep 10

./scripts/offloading/snapshot_offloading.sh
