#!/usr/bin/env python3

import argparse
import csv
import glob
import json
import os
import re

# =====================================================
# ARGOMENTI
# =====================================================

parser = argparse.ArgumentParser(
    description="Parsing risultati k6 (--summary-export JSON) per un singolo rate"
)

parser.add_argument(
    "--rate",
    required=True,
    help="Rate analizzato (es. 100)"
)

parser.add_argument(
    "--runs-dir",
    required=True,
    help="Cartella contenente R<rate>_run*_summary.json"
)

parser.add_argument(
    "--output-dir",
    required=True,
    help="Cartella output CSV"
)

parser.add_argument(
    "--pattern",
    default="R{rate}_run*_summary.json",
    help="Pattern dei file summary k6 ({rate} viene sostituito dal rate)"
)

args = parser.parse_args()

MIB = 1024 * 1024

# =====================================================
# HELPER
# =====================================================

def metric(metrics, name):
    """Dict di una metrica, vuoto se assente (es. checks, dropped_iterations)."""
    m = metrics.get(name)
    return m if isinstance(m, dict) else {}

def rnd(x, nd=2):
    return round(x, nd) if isinstance(x, (int, float)) else None

def pct(x):
    return rnd(x * 100) if isinstance(x, (int, float)) else None

def mib(x):
    return rnd(x / MIB) if isinstance(x, (int, float)) else None

def to_num(s):
    """'100' -> 100, '0.5' -> 0.5, altrimenti la stringa originale."""
    for cast in (int, float):
        try:
            return cast(s)
        except ValueError:
            pass
    return s

# =====================================================
# PARSING SUMMARY (UNA RUN)
# =====================================================

def parse_summary(filename):
    with open(filename, "r") as f:
        data = json.load(f)

    metrics = data.get("metrics")
    if not metrics:
        raise Exception(f"Campo 'metrics' non trovato in {filename}")

    reqs = metric(metrics, "http_reqs")
    failed = metric(metrics, "http_req_failed")
    dur = metric(metrics, "http_req_duration")
    blocked = metric(metrics, "http_req_blocked")
    waiting = metric(metrics, "http_req_waiting")
    receiving = metric(metrics, "http_req_receiving")
    iters = metric(metrics, "iterations")
    iter_dur = metric(metrics, "iteration_duration")
    dropped = metric(metrics, "dropped_iterations")
    vus = metric(metrics, "vus")
    vus_max = metric(metrics, "vus_max")
    checks = metric(metrics, "checks")
    sent = metric(metrics, "data_sent")
    recv = metric(metrics, "data_received")

    # durata effettiva del test ricavata da count/rate
    duration_s = None
    if reqs.get("count") is not None and reqs.get("rate"):
        duration_s = reqs["count"] / reqs["rate"]

    return {
        # throughput
        "test_duration_s": rnd(duration_s, 1),
        "total_requests": reqs.get("count"),
        "requests_per_sec": rnd(reqs.get("rate")),
        "iterations": iters.get("count"),
        "dropped_iterations": dropped.get("count", 0),

        # errori
        "failed_requests": failed.get("passes"),
        "error_rate_%": pct(failed.get("value")),
        "checks_pass_rate_%": pct(checks.get("value")),

        # latenza totale (ms)
        "latency_avg_ms": rnd(dur.get("avg")),
        "latency_min_ms": rnd(dur.get("min")),
        "latency_med_ms": rnd(dur.get("med")),
        "latency_p90_ms": rnd(dur.get("p(90)")),
        "latency_p95_ms": rnd(dur.get("p(95)")),
        "latency_p99_ms": rnd(dur.get("p(99)")),
        "latency_max_ms": rnd(dur.get("max")),

        # componenti della latenza (ms)
        "blocked_avg_ms": rnd(blocked.get("avg")),
        "waiting_avg_ms": rnd(waiting.get("avg")),
        "waiting_p95_ms": rnd(waiting.get("p(95)")),
        "receiving_avg_ms": rnd(receiving.get("avg")),
        "receiving_p95_ms": rnd(receiving.get("p(95)")),
        "iteration_duration_avg_ms": rnd(iter_dur.get("avg")),

        # VU: picco usato vs massimo disponibile
        "vus_peak": vus.get("max"),
        "vus_max": vus_max.get("value"),

        # rete
        "data_sent_MiB": mib(sent.get("count")),
        "data_received_MiB": mib(recv.get("count")),
        "data_received_MiB_per_s": mib(recv.get("rate")),
    }

# =====================================================
# SALVATAGGIO CSV
# =====================================================

def save_csv(filename, data):
    if not data:
        return

    with open(filename, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=data[0].keys())
        writer.writeheader()
        writer.writerows(data)

# =====================================================
# MAIN
# =====================================================

def main():
    pattern = args.pattern.format(rate=args.rate)
    files = sorted(glob.glob(os.path.join(args.runs_dir, pattern)))

    if not files:
        raise Exception(
            f"Nessun file {pattern} trovato in {args.runs_dir}"
        )

    os.makedirs(args.output_dir, exist_ok=True)

    rows = []

    for filename in files:
        print(f"Analizzo {filename}")

        m = re.search(r"run\d+", os.path.basename(filename))
        run_name = m.group(0) if m else os.path.basename(filename)  # run1, run2, ...

        row = {"rate": to_num(args.rate), "run": run_name}
        row.update(parse_summary(filename))
        rows.append(row)

    output_csv = os.path.join(args.output_dir, f"R{args.rate}_k6_runs.csv")
    save_csv(output_csv, rows)

    print()
    print("===================================")
    print("Analisi k6 completata")
    print("Rate:", args.rate)
    print("Run analizzate:", len(files))
    print()
    print("Output:")
    print(output_csv)
    print("===================================")

if __name__ == "__main__":
    main()