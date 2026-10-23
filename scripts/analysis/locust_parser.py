#!/usr/bin/env python3
"""
Aggrega i CSV di Locust (*_stats.csv) per livello di utenti.
Per ogni livello calcola media e deviazione standard campionaria tra le run.

Uso:
    python3 parse_locust.py results/<TEST>/workload_test
    python3 parse_locust.py results/<TEST>/workload_test --name /cart/checkout -o checkout.csv

--name sceglie la riga del CSV (default "Aggregated"; per un singolo endpoint usa il suo
path, ad esempio /cart/checkout oppure /product/<id> non aggregato).
Solo libreria standard.
"""
import argparse
import csv
import re
import statistics
import sys
from pathlib import Path

# nome colonna in uscita -> funzione che la ricava da una riga del CSV di Locust
def num(row, col):
    return float(row[col])

METRICS = {
    "requests": lambda r: num(r, "Request Count"),
    "requests_per_sec": lambda r: num(r, "Requests/s"),
    "failures": lambda r: num(r, "Failure Count"),
    "failure_rate_pct": lambda r: 100.0 * num(r, "Failure Count") / num(r, "Request Count"),
    "latency_avg_ms": lambda r: num(r, "Average Response Time"),
    "latency_med_ms": lambda r: num(r, "Median Response Time"),
    "latency_p90_ms": lambda r: num(r, "90%"),
    "latency_p95_ms": lambda r: num(r, "95%"),
    "latency_p99_ms": lambda r: num(r, "99%"),
    "latency_max_ms": lambda r: num(r, "Max Response Time"),
}


def read_row(path, name):
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            if row.get("Name") == name:
                return row
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("base_dir", help="cartella workload_test con le sottocartelle U<utenti>/raw")
    ap.add_argument("--name", default="Aggregated", help="riga da analizzare (default: Aggregated)")
    ap.add_argument("-o", "--output", default=None, help="file CSV di uscita (default: <base_dir>/summary_locust.csv)")
    args = ap.parse_args()

    base = Path(args.base_dir)
    files = sorted(base.glob("U*/raw/*_stats.csv"))
    if not files:
        sys.exit(f"Nessun file *_stats.csv trovato in {base}/U*/raw/")

    per_level = {}
    for path in files:
        m = re.match(r"U(\d+)", path.parts[-3])
        if not m:
            continue
        users = int(m.group(1))
        row = read_row(path, args.name)
        if row is None:
            print(f"Attenzione: riga '{args.name}' non trovata in {path.name}", file=sys.stderr)
            continue
        try:
            values = {k: fn(row) for k, fn in METRICS.items()}
        except (ValueError, ZeroDivisionError, KeyError) as e:
            print(f"Attenzione: {path.name} saltato ({e!r})", file=sys.stderr)
            continue
        per_level.setdefault(users, []).append(values)

    out_path = Path(args.output) if args.output else base / "summary_locust.csv"
    header = ["users", "runs"]
    for k in METRICS:
        header += [f"{k}_mean", f"{k}_std"]

    with open(out_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        for users in sorted(per_level):
            runs = per_level[users]
            line = [users, len(runs)]
            for k in METRICS:
                vals = [r[k] for r in runs]
                mean = statistics.fmean(vals)
                std = statistics.stdev(vals) if len(vals) > 1 else 0.0
                line += [round(mean, 2), round(std, 2)]
            w.writerow(line)

    print(f"Scritto {out_path}")
    print(f"{'users':>6} {'runs':>4} {'req/s':>16} {'fail%':>14} {'avg ms':>16} {'p95 ms':>16}")
    for users in sorted(per_level):
        runs = per_level[users]

        def ms(key):
            vals = [r[key] for r in runs]
            sd = statistics.stdev(vals) if len(vals) > 1 else 0.0
            return f"{statistics.fmean(vals):.1f}±{sd:.1f}"

        print(f"{users:>6} {len(runs):>4} {ms('requests_per_sec'):>16} {ms('failure_rate_pct'):>14} "
              f"{ms('latency_avg_ms'):>16} {ms('latency_p95_ms'):>16}")


if __name__ == "__main__":
    main()