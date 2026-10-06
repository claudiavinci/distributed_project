#!/usr/bin/env python3

import argparse
import csv
import glob
import os
import requests
from datetime import datetime
from collections import defaultdict

# =====================================================
# CONFIGURAZIONE
# =====================================================

PROMETHEUS_URL = "http://localhost:9090"

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

args = parser.parse_args()

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
        }
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

# =====================================================
# QUERY
# =====================================================

pod_memory_query = """
sum by(pod)(
 container_memory_usage_bytes{
  namespace="shop",
  container!="POD",
  container!=""
 }
)
"""

pod_cpu_query = """
sum by(pod)(
 rate(
  container_cpu_usage_seconds_total{
   namespace="shop",
   container!="POD",
   container!=""
  }[5m]
 )
)
"""

node_memory_query = """
100 *
(
1 -
node_memory_MemAvailable_bytes
/
node_memory_MemTotal_bytes
)
"""

node_cpu_query = """
100 *
(
1 -
avg by(instance)(
 rate(
  node_cpu_seconds_total{
   mode="idle"
  }[5m]
 )
)
)
"""

# =====================================================
# ELABORA UNA RUN
# =====================================================

def collect_run(times_file):
    start, end = read_times_file(times_file)
    start_time = datetime.fromtimestamp(start).strftime(
        "%Y-%m-%d %H:%M:%S"
    )

    end_time = datetime.fromtimestamp(end).strftime(
        "%Y-%m-%d %H:%M:%S"
    )
    print(
        f"Analizzo {times_file}"
    )

    pod_memory = prometheus_query(
        pod_memory_query,
        start,
        end
    )

    pod_cpu = prometheus_query(
        pod_cpu_query,
        start,
        end
    )

    node_memory = prometheus_query(
        node_memory_query,
        start,
        end
    )

    node_cpu = prometheus_query(
        node_cpu_query,
        start,
        end
    )

    # POD

    pods_memory = extract_label(
        pod_memory,
        "pod"
    )

    pods_cpu = extract_label(
        pod_cpu,
        "pod"
    )
    
    pod_report = []

    for pod in sorted(
        set(pods_memory.keys())
        |
        set(pods_cpu.keys())
    ):
        mem = calculate_stats(
            pods_memory.get(pod, [])
        )


        cpu = calculate_stats(
            pods_cpu.get(pod, [])
        )

        pod_report.append({
            "pod": pod,

            "memory_avg_MiB":
                round(mem["avg"]/1024/1024,2)
                if mem["avg"] else None,

            "memory_max_MiB":
                round(mem["max"]/1024/1024,2)
                if mem["max"] else None,

            "cpu_avg_millicores":
                round(cpu["avg"]*1000,2)
                if cpu["avg"] else None,

            "cpu_max_millicores":
                round(cpu["max"]*1000,2)
                if cpu["max"] else None,
                
            # informazioni temporali run
            "start_ts": start,
            "end_ts": end,

            "start_time": start_time,
            "end_time": end_time
        })

    # NODE
    nodes_memory = extract_label(
        node_memory,
        "instance"
    )

    nodes_cpu = extract_label(
        node_cpu,
        "instance"
    )

    node_report = []

    for node in sorted(

        set(nodes_memory.keys())
        |
        set(nodes_cpu.keys())
    ):

        mem = calculate_stats(
            nodes_memory.get(node, [])
        )

        cpu = calculate_stats(
            nodes_cpu.get(node, [])
        )

        node_report.append({

            "node": node,
            "memory_avg_%":
                round(mem["avg"],2)
                if mem["avg"] else None,

            "memory_max_%":
                round(mem["max"],2)
                if mem["max"] else None,

            "cpu_avg_%":
                round(cpu["avg"],2)
                if cpu["avg"] else None,

            "cpu_max_%":
                round(cpu["max"],2)
                if cpu["max"] else None,
                
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

    with open(
        filename,
        "w",
        newline=""
    ) as f:

        writer = csv.DictWriter(
            f,
            fieldnames=data[0].keys()
        )

        writer.writeheader()
        writer.writerows(data)

# =====================================================
# MAIN
# =====================================================

times_files = sorted(
    glob.glob(
        os.path.join(
            args.runs_dir,
            "run*_times.txt"
        )
    )
)

if not times_files:
    raise Exception(
        "Nessun file run*_times.txt trovato"
    )

all_pods = []
all_nodes = []

for times in times_files:

    pods, nodes = collect_run(times)
    run_name = os.path.basename(times)\
        .replace("_times.txt","")

    save_csv(
        f"{args.output_prefix}_{run_name}_pods.csv",
        pods
    )

    save_csv(
        f"{args.output_prefix}_{run_name}_nodes.csv",
        nodes
    )

    for p in pods:
        p["run"] = run_name
        all_pods.append(p)

    for n in nodes:
        n["run"] = run_name
        all_nodes.append(n)

# =====================================================
# MEDIA TRA RUN
# =====================================================

def average_runs(data, key):

    grouped = defaultdict(list)

    for item in data:
        grouped[item[key]].append(item)

    result=[]
    
    for name, values in grouped.items():
        row={key:name}
        for field in values[0]:
            if field not in [key,"run"]:
                nums=[
                    x[field]
                    for x in values
                    if x[field] is not None
                ]
                if nums:
                    row[field]=round(
                        sum(nums)/len(nums),
                        2
                    )
        result.append(row)
    return result

avg_pods = average_runs(
    all_pods,
    "pod"
)

avg_nodes = average_runs(
    all_nodes,
    "node"
)

save_csv(
    f"{args.output_prefix}_average_pods.csv",
    avg_pods
)

save_csv(
    f"{args.output_prefix}_average_nodes.csv",
    avg_nodes
)

print()
print("===================================")
print("Analisi completata")
print("Run analizzate:", len(times_files))
print()
print("Output:")
print(
    f"{args.output_prefix}_average_pods.csv"
)
print(
    f"{args.output_prefix}_average_nodes.csv"
)
print("===================================")