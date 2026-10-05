#!/bin/bash

# Cartella di output
OUTPUT_DIR="experiments/baseline/snapshot"

export KUBECONFIG="$(pwd)/consumer-config"

mkdir -p "$OUTPUT_DIR"

echo "Raccolta snapshot Kubernetes..."
echo "Output: $OUTPUT_DIR"
echo "Kubeconfig: $KUBECONFIG"

# Risorse Kubernetes
kubectl get nodes -o json > "$OUTPUT_DIR/nodes.json"
kubectl get pods -n shop -o json > "$OUTPUT_DIR/pods.json"
kubectl get deployments -n shop -o json > "$OUTPUT_DIR/deployments.json"
kubectl get services -n shop -o json > "$OUTPUT_DIR/services.json"

# Eventi applicazione e cluster
kubectl get events -n shop -o json > "$OUTPUT_DIR/shop_events.json"
kubectl get events -A -o json > "$OUTPUT_DIR/all_events.json"

# Metriche
kubectl top nodes > "$OUTPUT_DIR/top_nodes.txt"
kubectl top pods -n shop > "$OUTPUT_DIR/top_pods.txt"

echo "Snapshot completato!"
echo "File salvati in: $OUTPUT_DIR"