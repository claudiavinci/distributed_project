#!/bin/bash

# Cartella di output
# OUTPUT_DIR="experiments/baseline/snapshot"
OUTPUT_DIR="experiments/offloading_stateless/snapshot"


export KUBECONFIG="$(pwd)/consumer-config"

mkdir -p "$OUTPUT_DIR"

echo "Raccolta snapshot Kubernetes..."
echo "Output: $OUTPUT_DIR"
echo "Kubeconfig: $KUBECONFIG"

# Risorse Kubernetes
# kubectl get nodes -o json > "$OUTPUT_DIR/nodes.json"
# kubectl get pods -n shop -o json > "$OUTPUT_DIR/pods.json"
# kubectl get deployments -n shop -o json > "$OUTPUT_DIR/deployments.json"
# kubectl get services -n shop -o json > "$OUTPUT_DIR/services.json"

# Eventi applicazione e cluster
# kubectl get events -n shop -o json > "$OUTPUT_DIR/shop_events.json"
# kubectl get events -A -o json > "$OUTPUT_DIR/all_events.json"

# Metriche
kubectl top nodes > "$OUTPUT_DIR/top_nodes.txt"
kubectl top pods -n shop > "$OUTPUT_DIR/top_pods.txt"
kubectl get nodes -o wide > "$OUTPUT_DIR/nodes.txt"
kubectl get pods -n shop -o wide > "$OUTPUT_DIR/shop_pods.txt"
kubectl get deployments -n shop > "$OUTPUT_DIR/deployments.txt"
kubectl get svc -n shop > "$OUTPUT_DIR/services.txt"
kubectl get events -A > "$OUTPUT_DIR/events.txt"
kubectl get virtualnodes -A > "$OUTPUT_DIR/virtual_nodes.txt"
kubectl get offloadingpolicies -A > "$OUTPUT_DIR/offloading_policies.txt"

echo "Snapshot completato!"
echo "File salvati in: $OUTPUT_DIR"