#!/usr/bin/env python3

import argparse
import csv
import glob
import os
import requests
from datetime import datetime
from collections import defaultdict


# =====================================================
# ARGOMENTI
# =====================================================

parser = argparse.ArgumentParser(
    description="Estrazione metriche Kubernetes da Prometheus"
)

parser.add_argument(
    "--namespace",
    default="shop"
)

parser.add_argument(
    "--runs-dir",
    required=True,
    help="Cartella contenente run*_times.txt"
)

parser.add_argument(
    "--output-prefix",
    required=True,
    help="Prefisso output CSV"
)

parser.add_argument(
    "--step",
    default="5s"
)

parser.add_argument(
    "--prometheus-url",
    default="http://localhost:9090"
)


args = parser.parse_args()

PROMETHEUS_URL = args.prometheus_url
RATE_WINDOW = 60  # secondi

# =====================================================
# LETTURA TIMESTAMP
# =====================================================

def read_times_file(filename):

    start = None
    end = None

    with open(filename, "r") as f:
        for line in f:
            if line.startswith("start="):
                start = int(
                    line.split("=")[1]
                )
            elif line.startswith("end="):
                end = int(
                    line.split("=")[1]
                )

    if start is None or end is None:
        raise Exception(
            f"Timestamp non trovati in {filename}"
        )
    return start, end

# =====================================================
# QUERY PROMETHEUS
# =====================================================

def prometheus_query(query, start, end):
    response = requests.get(
        f"{PROMETHEUS_URL}/api/v1/query_range",
        params={
            "query": query,
            "start": start,
            "end": end,
            "step": args.step
        },
        timeout=30
    )

    response.raise_for_status()
    result = response.json()

    if result["status"] != "success":
        raise Exception(result)
    
    return result["data"]["result"]

# =====================================================
# STATISTICHE
# =====================================================

def calculate_stats(values):
    values = [
        float(v[1])
        for v in values
    ]

    if not values:
        return {
            "avg": None,
            "max": None
        }
        
    return {
        "avg": sum(values)/len(values),
        "max": max(values)
    }

def extract_label(data, label):
    result = {}
    for item in data:
        name = item["metric"].get(label)
        if name:
            result[name] = item["values"]
    return result

def extract_pod_node(data, labels):
    result = {}
    for item in data:
        key = tuple(
            item["metric"].get(label)
            for label in labels
        )
        if all(key):
            result[key] = item["values"]

    return result
# =====================================================
# QUERY
# =====================================================

pod_memory_query = f"""
sum by(pod, node)(
    container_memory_usage_bytes{{
        namespace="{args.namespace}",
        container!="POD",
        container!=""
    }}
)
"""

pod_cpu_query = f"""
sum by(pod, node)(
    rate(
        container_cpu_usage_seconds_total{{
        namespace="{args.namespace}",
        container!="POD",
        container!=""
        }}[1m]
    )
)
"""

node_memory_query = """
100 * (
    1 - node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes
)
"""

node_cpu_query = """
100 * (
    1 - avg by(instance)(
        rate(
            node_cpu_seconds_total{
            mode="idle"
            }[1m]
        )
    )
)
"""

# =====================================================
# ELABORA UNA RUN
# =====================================================

def collect_run(times_file):
    start, end = read_times_file(times_file)
    cpu_start = start + RATE_WINDOW

    start_time = datetime.fromtimestamp(start).strftime("%Y-%m-%d %H:%M:%S")
    end_time = datetime.fromtimestamp(end).strftime("%Y-%m-%d %H:%M:%S")
    print(f"Analizzo {times_file}")

    pod_memory = prometheus_query(pod_memory_query, start, end)
    pod_cpu = prometheus_query(pod_cpu_query, cpu_start, end)

    node_memory = prometheus_query(node_memory_query, start, end)
    node_cpu = prometheus_query(node_cpu_query, cpu_start, end)

    # POD

    pods_memory = extract_pod_node(pod_memory, ["pod", "node"])
    pods_cpu = extract_pod_node(pod_cpu, ["pod", "node"])
    
    pod_report = []

    for pod, node in sorted(set(pods_memory.keys()) | set(pods_cpu.keys())):

        mem = calculate_stats(pods_memory.get((pod, node), []))
        cpu = calculate_stats(pods_cpu.get((pod, node), []))

        pod_report.append({
            "pod": pod,
            "node": node,

            "memory_avg_MiB":
                round(mem["avg"]/1024/1024,2)
                if mem["avg"] is not None else None,

            "memory_max_MiB":
                round(mem["max"]/1024/1024,2)
                if mem["max"] is not None else None,

            "cpu_avg_millicores":
                round(cpu["avg"]*1000,2)
                if cpu["avg"] is not None else None,

            "cpu_max_millicores":
                round(cpu["max"]*1000,2)
                if cpu["max"] is not None else None,
                
            # informazioni temporali run
            "start_ts": start,
            "end_ts": end,
            "start_time": start_time,
            "end_time": end_time
        })

    # NODE
    nodes_memory = extract_label(node_memory, "instance")
    nodes_cpu = extract_label(node_cpu, "instance")

    node_report = []

    for node in sorted(set(nodes_memory.keys()) | set(nodes_cpu.keys())):

        mem = calculate_stats(nodes_memory.get(node, []))
        cpu = calculate_stats(nodes_cpu.get(node, []))

        node_report.append({
            "node": node,

            "memory_avg_%":
                round(mem["avg"],2)
                if mem["avg"] is not None else None,

            "memory_max_%":
                round(mem["max"],2)
                if mem["max"] is not None else None,

            "cpu_avg_%":
                round(cpu["avg"],2)
                if cpu["avg"] is not None else None,

            "cpu_max_%":
                round(cpu["max"],2)
                if cpu["max"] is not None else None,
                
            # informazioni temporali run
            "start_ts": start,
            "end_ts": end,
            "start_time": start_time,
            "end_time": end_time
        })

    return pod_report, node_report

# =====================================================
# SALVATAGGIO CSV
# =====================================================

def save_csv(filename,data):
    if not data:
        return

    with open(filename, "w", newline="", encoding="utf-8") as f:

        writer = csv.DictWriter(f, fieldnames=data[0].keys())
        writer.writeheader()
        writer.writerows(data)

# =====================================================
# MEDIA TRA RUN
# =====================================================

def average_runs(data, key):
    grouped = defaultdict(list)
    for item in data:
        if key == "pod":
            group_key = (item["pod"], item["node"])
        else:
            group_key = item[key]
        grouped[group_key].append(item)
    result = []

    for name, values in grouped.items():
        row = {}

        if key == "pod":
            row["pod"] = name[0]
            row["node"] = name[1]
        else:
            row[key] = name

        for field in values[0]:
            if field in [
                "pod",
                "node",
                "run",
                "start_ts",
                "end_ts",
                "start_time",
                "end_time"
            ]:
                continue
            nums=[]
            for x in values:
                value = x.get(field)
                if value is not None:
                    try:
                        nums.append(float(value))
                    except ValueError:
                        pass
            if nums:
                row[field] = round(sum(nums)/len(nums),2)
        result.append(row)
    return result

# =====================================================
# MAIN
# =====================================================

def main():
    times_files = sorted(glob.glob(os.path.join(args.runs_dir, "run*_times.txt")))

    if not times_files:
        raise Exception("Nessun file run*_times.txt trovato")

    all_pods = []
    all_nodes = []

    for times in times_files:

        pods, nodes = collect_run(times)
        run_name = os.path.basename(times).replace("_times.txt","")

        save_csv(f"{args.output_prefix}_{run_name}_pods.csv", pods)
        save_csv(f"{args.output_prefix}_{run_name}_nodes.csv", nodes)

        for p in pods:
            p["run"] = run_name
            all_pods.append(p)

        for n in nodes:
            n["run"] = run_name
            all_nodes.append(n)
    
    avg_pods = average_runs(all_pods, "pod")
    avg_nodes = average_runs(all_nodes, "node")

    save_csv(f"{args.output_prefix}_average_pods.csv", avg_pods)
    save_csv(f"{args.output_prefix}_average_nodes.csv", avg_nodes)
    
    print()
    print("===================================")
    print("Analisi completata")
    print("Run analizzate:", len(times_files))
    print()
    print("Output:")
    print(f"{args.output_prefix}_average_pods.csv")
    print(f"{args.output_prefix}_average_nodes.csv")
    print("===================================")

if __name__ == "__main__":
    main()
