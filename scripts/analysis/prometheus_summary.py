#!/usr/bin/env python3

import argparse
import csv
import statistics
import re
import sys

from pathlib import Path
from collections import defaultdict
from datetime import datetime

# =====================================================
# ARGOMENTI
# =====================================================

parser = argparse.ArgumentParser(
    description="Aggrega CSV Prometheus delle singole run"
)

parser.add_argument(
    "base_dir",
    help="cartella workload_test contenente U*/metrics_csv"
)

parser.add_argument(
    "--output-dir",
    default=None,
    help="cartella output summary"
)

args = parser.parse_args()

base = Path(args.base_dir)

output_dir = (Path(args.output_dir) if args.output_dir else base)

# =====================================================
# LETTURA CSV
# =====================================================

def read_csv(path):

    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

# =====================================================
# AGGREGAZIONE
# =====================================================

def build_summary(rows, group_keys):

    grouped = defaultdict(list)

    # raggruppa
    for row in rows:
        key = tuple(row[k] for k in group_keys)
        grouped[key].append(row)

    summary=[]

    for key, values in grouped.items():
        summary_row={}

        # chiavi gruppo
        for i,k in enumerate(group_keys):
            summary_row[k]=key[i]

        # numero di run aggregate
        summary_row["runs"]=len(values)

        # durata totale esperimento
        starts=[int(x["start_ts"]) for x in values]
        ends=[int(x["end_ts"]) for x in values]

        exp_start=min(starts)
        exp_end=max(ends)

        summary_row["exp_start_time"] = datetime.fromtimestamp(exp_start).strftime("%Y-%m-%d %H:%M:%S")
        summary_row["exp_end_time"] = datetime.fromtimestamp(exp_end).strftime("%Y-%m-%d %H:%M:%S")

        # metriche numeriche

        ignore = set(
            group_keys +
            [
                "start_ts",
                "end_ts",
                "start_time",
                "end_time"
            ]
        )

        metrics = []

        for k in values[0].keys():
            if k not in ignore:
                metrics.append(k)

        for metric in metrics:
            nums=[]

            for row in values:
                value=row.get(metric)
                if value not in ("",None):
                    nums.append(float(value))

            if nums:
                summary_row[f"{metric}_mean"] = round(statistics.fmean(nums), 3)
                summary_row[f"{metric}_std"] = round(statistics.stdev(nums) if len(nums)>1 else 0.0, 3)

        summary.append(summary_row)

    return summary

# =====================================================
# SALVATAGGIO
# =====================================================

def save_csv(path,data):

    if not data:
        return
    
    with open(path,"w", newline="", encoding="utf-8") as f:

        writer=csv.DictWriter(f, fieldnames=data[0].keys())
        writer.writeheader()
        writer.writerows(data)

# =====================================================
# MAIN
# =====================================================

def main():

    all_pods=[]
    all_nodes=[]

    metric_dirs=sorted(base.glob("U*/metrics_csv"))

    if not metric_dirs:
        sys.exit("Nessuna cartella U*/metrics_csv trovata")

    for metric_dir in metric_dirs:
        # esempio:
        # U300/metrics_csv

        match=re.search(r"U(\d+)", str(metric_dir))

        if not match:
            continue

        users=int(match.group(1))

        pod_files=sorted(metric_dir.glob("*_pods.csv"))
        node_files=sorted(metric_dir.glob("*_nodes.csv"))

        for file in pod_files:
            rows=read_csv(file)
            for row in rows:
                row["users"]=users
            all_pods.extend(rows)

        for file in node_files:
            rows=read_csv(file)
            for row in rows:
                row["users"]=users
            all_nodes.extend(rows)

    # summary pod

    pod_summary=build_summary(all_pods,["users", "pod", "node"])

    save_csv(output_dir / "prometheus_pods_summary.csv", pod_summary)

    # summary node
    node_summary=build_summary(all_nodes, ["users", "node"])

    save_csv(output_dir / "prometheus_nodes_summary.csv", node_summary)

    print()
    print("============================")
    print("Summary Prometheus creati")
    print("============================")
    print()
    print(output_dir / "prometheus_pods_summary.csv")
    print(output_dir / "prometheus_nodes_summary.csv")

if __name__=="__main__":
    main()