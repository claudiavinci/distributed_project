#!/usr/bin/env python3

import argparse
import csv
import glob
import os
import statistics
from collections import defaultdict

# =====================================================
# ARGOMENTI
# =====================================================

parser = argparse.ArgumentParser(
    description="Riepilogo k6: media e std per rate da tutti gli R*_k6_runs.csv"
)

parser.add_argument(
    "--input-glob",
    required=True,
    help="Glob degli R*_k6_runs.csv di tutti i rate (tra virgolette)"
)

parser.add_argument(
    "--output-dir",
    required=True,
    help="Cartella dei CSV di riepilogo"
)

args = parser.parse_args()

OUTPUT_DIR = args.output_dir

# =====================================================
# HELPER
# =====================================================

def to_float(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def clean_rate(x):
    """100.0 -> 100"""
    return int(x) if float(x).is_integer() else x


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
    files = sorted(glob.glob(args.input_glob))

    if not files:
        raise Exception(
            f"Nessun file trovato con il glob: {args.input_glob}"
        )

    # raggruppo le righe (una per run) per rate
    by_rate = defaultdict(list)
    fields = []

    for filename in files:
        with open(filename, newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)

            for col in reader.fieldnames:
                if col not in ("rate", "run") and col not in fields:
                    fields.append(col)

            for row in reader:
                rate = to_float(row["rate"])
                if rate is None:
                    raise Exception(f"Rate non valido in {filename}")
                by_rate[rate].append(row)

    means = []
    stds = []

    for rate in sorted(by_rate):
        rows = by_rate[rate]

        mean_row = {"rate": clean_rate(rate), "runs": len(rows)}
        std_row = {"rate": clean_rate(rate), "runs": len(rows)}

        for field in fields:
            nums = [
                v for v in (to_float(r.get(field)) for r in rows)
                if v is not None
            ]

            # colonne sempre presenti, vuote se la metrica manca
            mean_row[field] = round(sum(nums) / len(nums), 2) if nums else None

            if len(nums) > 1:
                std_row[field] = round(statistics.stdev(nums), 2)
            else:
                std_row[field] = 0.0 if nums else None

        means.append(mean_row)
        stds.append(std_row)

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    summary_csv = os.path.join(OUTPUT_DIR, "k6_summary.csv")
    std_csv = os.path.join(OUTPUT_DIR, "k6_summary_std.csv")

    save_csv(summary_csv, means)
    save_csv(std_csv, stds)

    print("===================================")
    print("Riepilogo k6 completato")
    print("Rate nel riepilogo:", ", ".join(str(m["rate"]) for m in means))
    print()
    print("Output:")
    print(summary_csv)
    print(std_csv)
    print("===================================")

if __name__ == "__main__":
    main()