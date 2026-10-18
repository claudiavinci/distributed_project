#!/bin/bash

# Cartella di output
OUTPUT_DIR="results/baseline/snapshot"

export KUBECONFIG="$(pwd)/consumer-config"

mkdir -p "$OUTPUT_DIR"

echo "Raccolta snapshot baseline Kubernetes..."
echo "Output: $OUTPUT_DIR"
echo "Kubeconfig: $KUBECONFIG"

# ----------Risorse Kubernetes---------------------

kubectl get nodes -o json > "$OUTPUT_DIR/nodes.json"
kubectl describe nodes > "$OUTPUT_DIR/nodes_description.txt"
kubectl get nodes -o wide > "$OUTPUT_DIR/nodes.txt"
kubectl get pods -n shop -o json > "$OUTPUT_DIR/pods.json"
kubectl get pods -n shop -o wide > "$OUTPUT_DIR/pods.txt"
kubectl get deployments -n shop -o json > "$OUTPUT_DIR/deployments.json"

# ----------Eventi applicazione e cluster----------

kubectl get events -n shop -o json > "$OUTPUT_DIR/shop_events.json"
kubectl get events -A -o json > "$OUTPUT_DIR/all_events.json"

# ---------------------Metriche---------------------
kubectl top nodes > "$OUTPUT_DIR/top_nodes.txt"
kubectl top pods -n shop > "$OUTPUT_DIR/top_pods.txt"

echo "Snapshot completato!"
echo "File salvati in: $OUTPUT_DIR"