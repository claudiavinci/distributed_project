#!/bin/bash

OUTPUT_DIR="experiments/offloading_stateless/snapshot"

export KUBECONFIG="$(pwd)/consumer-config"

mkdir -p "$OUTPUT_DIR"

echo "Raccolta snapshot offloading..."
echo "Output: $OUTPUT_DIR"

# Stato cluster e workload
kubectl get nodes -o wide > "$OUTPUT_DIR/nodes.txt"
kubectl get pods -n shop -o wide > "$OUTPUT_DIR/shop_pods.txt"

# Stato Liqo
kubectl get foreignclusters > "$OUTPUT_DIR/foreignclusters.txt"
kubectl get namespaceoffloading -n shop -o yaml > "$OUTPUT_DIR/namespace_offloading.yaml"
kubectl get nodes --show-labels | grep liqo > "$OUTPUT_DIR/liqo_virtual_node.txt"

# Risorse
kubectl top nodes > "$OUTPUT_DIR/top_nodes.txt"
kubectl top pods -n shop > "$OUTPUT_DIR/top_pods.txt"

echo "Snapshot completato!"
echo "File salvati in: $OUTPUT_DIR"