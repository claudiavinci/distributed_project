#!/usr/bin/env python3

import argparse
import csv
import os
import glob
import requests
import re

from pathlib import Path
from datetime import datetime

# =====================================================
# ARGOMENTI
# =====================================================

parser = argparse.ArgumentParser(
    description="Estrazione metriche Kubernetes da Prometheus"
)

parser.add_argument(
    "--base-dir",
    required=True,
    help="Cartella workload_test contenente U*/raw"
)

parser.add_argument(
    "--namespace",
    default="shop"
)

parser.add_argument(
    "--prometheus-url",
    default="http://localhost:9090"
)

parser.add_argument(
    "--step",
    default="5s"
)

args = parser.parse_args()

PROMETHEUS_URL = args.prometheus_url

RATE_WINDOW = 60

# =====================================================
# LETTURA TIMESTAMP RUN
# =====================================================

def read_times_file(filename):

    start = None
    end = None

    with open(filename) as f:
        for line in f:
            if line.startswith("start="):
                start = int(line.split("=")[1])
            elif line.startswith("end="):
                end = int(line.split("=")[1])

    if start is None or end is None:
        raise Exception(f"Timestamp non trovati in {filename}")

    return start, end

# =====================================================
# PROMETHEUS QUERY
# =====================================================

def prometheus_query(query,start,end):

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

    data=response.json()

    if data["status"]!="success":
        raise Exception(data)

    return data["data"]["result"]

# =====================================================
# STATISTICHE
# =====================================================

def calculate_stats(values):

    values=[float(v[1]) for v in values]

    if not values:
        return {
            "avg": None,
            "max": None
        }

    return {
        "avg": sum(values)/len(values),
        "max": max(values)
    }

# =====================================================
# ESTRAZIONE LABEL
# =====================================================

def extract_pod_node(data):

    result={}

    for item in data:

        pod=item["metric"].get("pod")
        node=item["metric"].get("node")

        if pod and node:
            result[(pod,node)] = item["values"]

    return result

def extract_node(data):

    result={}

    for item in data:

        node=item["metric"].get("node")

        if node:
            result[node]=item["values"]

    return result

# =====================================================
# QUERY
# =====================================================

pod_memory_query=f"""
    sum by(pod,node)(
        container_memory_usage_bytes{{
            namespace="{args.namespace}",
            container!="POD",
            container!=""
        }}
    )
"""

pod_cpu_query=f"""
    sum by(pod,node)(
        rate(
            container_cpu_usage_seconds_total{{
                namespace="{args.namespace}",
                container!="POD",
                container!=""
            }}
            [{RATE_WINDOW}s]
        )
    )
""" 

node_memory_query="""
    100 *
    sum by(node) (
    container_memory_working_set_bytes{}
    )
    / (6 * 1024 * 1024 * 1024)
"""


node_cpu_query=f"""
    100 * sum by(node) (
    rate(container_cpu_usage_seconds_total{{}}[{RATE_WINDOW}s])
    )
"""

# =====================================================
# RACCOLTA SINGOLA RUN
# =====================================================

def collect_run(times_file, users):

    start,end = read_times_file(times_file)

    cpu_start=start + RATE_WINDOW

    start_time=datetime.fromtimestamp(start)
    end_time=datetime.fromtimestamp(end)

    print(f"Analizzo {times_file}")

    pod_memory=prometheus_query(pod_memory_query, start, end)

    pod_cpu=prometheus_query(pod_cpu_query, cpu_start, end)

    node_memory=prometheus_query(node_memory_query, start, end)

    node_cpu=prometheus_query( node_cpu_query, cpu_start, end)

    # -------------------------
    # POD
    # -------------------------

    pods_memory=extract_pod_node(pod_memory)

    pods_cpu=extract_pod_node(pod_cpu)

    pod_report=[]

    for pod,node in sorted(set(pods_memory.keys()) | set(pods_cpu.keys())):

        mem=calculate_stats(pods_memory.get((pod,node),[]))

        cpu=calculate_stats(pods_cpu.get((pod,node),[]))

        pod_report.append({

            "users": users,
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

            "start_ts": start,
            "end_ts": end,
            "start_time": start_time.strftime("%Y-%m-%d %H:%M:%S"),
            "end_time": end_time.strftime("%Y-%m-%d %H:%M:%S")
        })

    # -------------------------
    # NODE
    # -------------------------

    nodes_memory=extract_node(node_memory)

    nodes_cpu=extract_node(node_cpu)

    node_report=[]

    for node in sorted(set(nodes_memory.keys()) | set(nodes_cpu.keys())):

        mem=calculate_stats(nodes_memory.get(node,[]))

        cpu=calculate_stats(nodes_cpu.get(node,[]))

        node_report.append({
            "users":users,
            "node":node,

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

            "start_ts": start,
            "end_ts": end,
            "start_time": start_time.strftime("%Y-%m-%d %H:%M:%S"),
            "end_time": end_time.strftime("%Y-%m-%d %H:%M:%S")
        })

    return pod_report,node_report

# =====================================================
# CSV
# =====================================================

def save_csv(filename,data):

    if not data:
        return

    with open(filename, "w", newline="", encoding="utf-8") as f:
        writer=csv.DictWriter(f,fieldnames=data[0].keys())
        writer.writeheader()
        writer.writerows(data)

# =====================================================
# MAIN
# =====================================================

def main():

    base=Path(args.base_dir)

    user_dirs=sorted(base.glob("U*/raw"))

    if not user_dirs:
        raise Exception("Nessuna cartella U*/raw trovata")

    for raw_dir in user_dirs:

        match=re.search(r"U(\d+)",str(raw_dir))

        users=int(match.group(1))

        output_dir=raw_dir.parent / "metrics_csv"

        output_dir.mkdir(parents=True, exist_ok=True)

        times_files=sorted(raw_dir.glob("run*_times.txt"))

        for times in times_files:

            run_name=times.stem.replace("_times","")

            pods,nodes=collect_run(times, users)

            save_csv(output_dir / f"{run_name}_pods.csv", pods)
            save_csv(output_dir / f"{run_name}_nodes.csv", nodes)

if __name__=="__main__":
    main()