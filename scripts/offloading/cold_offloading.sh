#!/bin/bash

# Misura dell'offloading a freddo di servizi stateless.
# Il manifest determina il placement:
# - nodeSelector liqo.io/type=virtual-node -> remoto
# - nessun nodeSelector remoto -> scheduling libero

set -euo pipefail

# =====================================
# CONFIG ESPERIMENTO
# =====================================

source configs/exp_config.conf

for v in TEST NAMESPACE MANIFEST BASE_MANIFEST DEPLOYMENTS_LIST; do
    if [ -z "${!v:-}" ]; then
        echo "Errore: variabile mancante: $v"
        exit 1
    fi
done

read -r -a DEPLOY_LIST <<< "$DEPLOYMENTS_LIST"

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
echo "Manifest: $MANIFEST"
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

# Verifica che non rimangano selector remoti
for d in "${DEPLOY_LIST[@]}"; do
    SELECTOR=$(kubectl get deployment "$d" -n "$NAMESPACE" -o json |
        jq -r '.spec.template.spec.nodeSelector["liqo.io/type"] // ""')

    if [ -n "$SELECTOR" ]; then
        echo "Errore: $d ha ancora il nodeSelector Liqo: $SELECTOR"
        exit 1
    fi
done

# =====================================
# BASELINE LOCALE
# =====================================

# echo "Preparo la baseline locale..."

# for d in "${DEPLOY_LIST[@]}"; do
#     kubectl rollout restart deployment/"$d" -n "$NAMESPACE"
# done

for d in "${DEPLOY_LIST[@]}"; do

    kubectl rollout status deployment/"$d" \
        -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"

    # Salva i nomi dei pod precedenti all'esperimento
    kubectl get pods -n "$NAMESPACE" -l "app=$d" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
        > "$TMP_DIR/$d.before"

    # Salva la generazione del template prima dell'apply
    kubectl get deployment "$d" -n "$NAMESPACE" \
        -o json | jq -S '.spec.template' \
        > "$TMP_DIR/$d.template.before"

    # Verifica baseline locale e Ready
    kubectl get pods -n "$NAMESPACE" -l "app=$d" -o json |
        jq -e --argjson expected \
            "$(kubectl get deployment "$d" -n "$NAMESPACE" \
                -o jsonpath='{.spec.replicas}')" '
            [.items[] | select(.metadata.deletionTimestamp == null)] as $pods
            | ($pods | length) == $expected
              and all($pods[];
                  .spec.nodeName != null
                  and any(.status.conditions[]?;
                      .type == "Ready" and .status == "True"))
        ' >/dev/null

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

echo "Inizio offloading..."

liqoctl offload namespace "$NAMESPACE" \
    --namespace-mapping-strategy EnforceSameName \
    --pod-offloading-strategy LocalAndRemote

kubectl wait \
    --for=jsonpath='{.status.offloadingPhase}'=Ready \
    namespaceoffloading/offloading \
    -n "$NAMESPACE" --timeout=120s

OFFLOAD_READY_TS=$(date +%s)

# =====================================
# APPLICAZIONE MANIFEST
# =====================================

echo "Applico il manifest sperimentale..."
kubectl apply -f "$MANIFEST" -n "$NAMESPACE"

# Riavvia soltanto i Deployment il cui template
# non e' cambiato con l'apply.
for d in "${DEPLOY_LIST[@]}"; do

    kubectl get deployment "$d" -n "$NAMESPACE" \
        -o json | jq -S '.spec.template' \
        > "$TMP_DIR/$d.template.after"

    if cmp -s \
        "$TMP_DIR/$d.template.before" \
        "$TMP_DIR/$d.template.after"; then

        echo "$d: template invariato, eseguo rollout restart"
        kubectl rollout restart deployment/"$d" -n "$NAMESPACE"

    else
        echo "$d: template modificato dal manifest"
    fi

done

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
# CALCOLO TEMPI E PLACEMENT
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

        # Tutti i pod devono essere nuovi
        if grep -Fxq "$POD" "$TMP_DIR/$d.before"; then
            echo "Errore: pod precedente ancora presente: $POD"
            exit 1
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

# =====================================
# PLACEMENT COMPLESSIVO NAMESPACE
# =====================================

NAMESPACE_REMOTE_COUNT=0
NAMESPACE_LOCAL_COUNT=0

while IFS= read -r NODE; do
    [ -z "$NODE" ] && continue

    if [[ " $VIRTUAL_NODES " == *" $NODE "* ]]; then
        NAMESPACE_REMOTE_COUNT=$((NAMESPACE_REMOTE_COUNT + 1))
    else
        NAMESPACE_LOCAL_COUNT=$((NAMESPACE_LOCAL_COUNT + 1))
    fi

done < <(
    kubectl get pods -n "$NAMESPACE" -o json |
        jq -r '.items[]
            | select(.metadata.deletionTimestamp == null)
            | .spec.nodeName // empty'
)

# =====================================
# METRICHE TEMPORALI
# =====================================

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
    echo "Manifest=$MANIFEST"
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
    echo "Selected_remote_pods_count=$REMOTE_COUNT"
    echo "Selected_local_pods_count=$LOCAL_COUNT"
    echo "Namespace_remote_pods_count=$NAMESPACE_REMOTE_COUNT"
    echo "Namespace_local_pods_count=$NAMESPACE_LOCAL_COUNT"
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
# SNAPSHOT FINALE
# =====================================

sleep 10

# ./scripts/offloading/snapshot_offloading.sh
