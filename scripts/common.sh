
#!/usr/bin/env bash

# Funzioni comuni per gli esperimenti di
# offloading e unoffloading a caldo con Liqo.

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
    printf '%s,%s,%s\n' \
        "$(timestamp)" "$(epoch_ms)" "$1" |
        tee -a "$EVENTS"
}

# =====================================
# VERIFICHE PRELIMINARI
# =====================================

check_requirements() {
    local v file cmd

    for v in "${REQUIRED_VARS[@]}"; do
        if [[ -z "${!v:-}" ]]; then
            echo "Errore: variabile mancante: $v"
            return 1
        fi
    done

    for file in \
        "$CONSUMER_CONFIG" \
        "$PROVIDER_CONFIG" \
        "$LOCUSTFILE_LOCAL" \
        "$MONITOR_SCRIPT"; do

        [[ -f "$file" ]] || {
            echo "Errore: file non trovato: $file"
            return 1
        }
    done

    for cmd in kubectl liqoctl; do
        command -v "$cmd" >/dev/null || {
            echo "Errore: comando non disponibile: $cmd"
            return 1
        }
    done

    (( ${#DEPLOY_LIST[@]} > 0 )) || {
    echo "Errore: DEPLOYMENTS_LIST vuota"
    exit 1
    }
}

# =====================================
# MONITORAGGIO
# =====================================

start_monitor() {
    local monitor_dir="$OUTPUT_DIR/$MONITOR_SUBDIR"

    mkdir -p "$monitor_dir"

    echo "Avvio monitoraggio cluster..."
    
    MONITOR_DEPLOYMENTS="${TARGET_LIST[*]}" \
    MONITOR_INTERVAL="$MONITOR_INTERVAL" \
    OUTPUT_DIR="$monitor_dir" \
        bash "$MONITOR_SCRIPT" &

    MONITOR_PID=$!

    echo "Monitor PID: $MONITOR_PID"
    echo "Output: $monitor_dir"
}

stop_monitor() {
    if [[ -n "${MONITOR_PID:-}" ]]; then
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

    if [[ -n "${LOCUST_PID:-}" ]]; then
        kill "$LOCUST_PID" 2>/dev/null || true
        wait "$LOCUST_PID" 2>/dev/null || true
    fi

    if (( ${POD_CREATED:-0} )); then
        consumer delete pod "$LOADGEN_POD" \
            -n "$NAMESPACE" \
            --ignore-not-found \
            --wait=false >/dev/null 2>&1 || true
    fi

    exit "$status"
}

# =====================================
# VERIFICA APPLICAZIONE
# =====================================

check_app_ready() {
    local deadline=$((SECONDS + READY_TIMEOUT))
    local deployment desired available all_ready

    echo "Verifico disponibilità applicazione..."

    while (( SECONDS < deadline )); do

        all_ready=1

        for deployment in "${DEPLOY_LIST[@]}"; do

            desired="$(consumer get deployment "$deployment" \
                -n "$NAMESPACE" \
                -o jsonpath='{.spec.replicas}' \
                --request-timeout=5s)" || {
                all_ready=0
                break
            }

            available="$(consumer get deployment "$deployment" \
                -n "$NAMESPACE" \
                -o jsonpath='{.status.availableReplicas}' \
                --request-timeout=5s)" || {
                all_ready=0
                break
            }

            if (( ${available:-0} < ${desired:-1} )); then
                all_ready=0
                break
            fi
        done

        if (( all_ready )); then
            return 0
        fi

        sleep 5
    done

    return 1
}

# =====================================
# POSIZIONAMENTO DEI POD
# =====================================

# Restituisce:
# remote = almeno un Pod Ready sul VirtualNode
# local  = almeno un Pod Ready locale,
#          nessuno Ready sul VirtualNode
# none   = nessun Pod Ready

placement_of() {
    local deployment="$1"
    local pods node ready type
    local found_local=0

    pods="$(consumer get pods \
        -n "$NAMESPACE" \
        -l "app=$deployment" \
        --field-selector='status.phase!=Failed' \
        -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        --request-timeout=5s)" || return 1

    while read -r node ready; do

        [[ -n "$node" && "$ready" == "True" ]] || continue

        type="$(consumer get node "$node" \
            -o jsonpath='{.metadata.labels.liqo\.io/type}' \
            --request-timeout=5s)" || return 1

        if [[ "$type" == "virtual-node" ]]; then
            echo "remote"
            return 0
        fi

        found_local=1

    done <<< "$pods"

    if (( found_local )); then
        echo "local"
    else
        echo "none"
    fi
}

# =====================================
# VERIFICA POSIZIONAMENTO
# =====================================

# Controlla tutti i Deployment in TARGET_LIST.

check_placement() {
    local expected="$1"
    local deployment placement

    for deployment in "${TARGET_LIST[@]}"; do

        placement="$(placement_of "$deployment")" || return 1

        [[ "$placement" == "$expected" ]] || return 1
    done

    return 0
}


# =====================================
# LOADGENERATOR
# =====================================

create_loadgen_pod() {
    local image

    image="$(consumer get deploy "$LOADGEN_DEPLOY" \
        -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[0].image}')" || return 1

    [[ -n "$image" ]] || {
        echo "Errore: immagine loadgenerator non trovata"
        return 1
    }

    echo "Spengo deployment $LOADGEN_DEPLOY..."

    consumer scale deploy "$LOADGEN_DEPLOY" \
        -n "$NAMESPACE" \
        --replicas=0

    consumer wait \
        --for=delete pod \
        -l "app=$LOADGEN_DEPLOY" \
        -n "$NAMESPACE" \
        --timeout=90s

    echo "Creo loadgenerator $LOADGEN_POD..."

    consumer delete pod "$LOADGEN_POD" \
        -n "$NAMESPACE" \
        --ignore-not-found \
        --wait=true

    consumer run "$LOADGEN_POD" \
        -n "$NAMESPACE" \
        --image="$image" \
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

        src="/tmp/${CSV_NAME}_${kind}.csv"
        dest="$RAW_DIR/${PREFIX}_${kind}.csv"

        if ! consumer exec -n "$NAMESPACE" "$LOADGEN_POD" \
            -- cat "$src" > "$dest" 2>/dev/null; then

            rm -f "$dest"
            echo "Attenzione: CSV $kind non disponibile"
        fi
    done
}

# =====================================
# SNAPSHOT KUBERNETES
# =====================================

save_snapshot() {
    local phase="$1"

    consumer get pods -n "$NAMESPACE" -o wide \
        > "$RAW_DIR/${PREFIX}_consumer_pods_${phase}.txt" || true

    provider get pods -A -o wide \
        > "$RAW_DIR/${PREFIX}_provider_pods_${phase}.txt" || true
}

# =====================================
# TIMESTAMP PROMETHEUS
# =====================================

save_run_times() {
    local start="$1"
    local end="$2"

    cat > "$RAW_DIR/run1_times.txt" <<EOF_TIMES
start=$start
end=$end
ramp_s=$RAMP_S
EOF_TIMES
}
