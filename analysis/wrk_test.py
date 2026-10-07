#!/usr/bin/env python3

import os
import glob
import re
import pandas as pd


# =====================================================
# CONVERSIONI
# =====================================================

def parse_time_to_ms(value):

    if not value:
        return None

    value = value.strip()

    number = float(re.sub("[a-zA-Z]", "", value))

    if value.endswith("us"):
        return number / 1000

    if value.endswith("ms"):
        return number

    if value.endswith("s"):
        return number * 1000

    return number

def parse_size_to_mb(value):
    if not value:
        return None

    value = value.strip().upper()

    number = float(re.sub("[A-Z]", "", value))

    if value.endswith("GB"):
        return number * 1024

    if value.endswith("MB"):
        return number

    if value.endswith("KB"):
        return number / 1024

    if value.endswith("B"):
        return number / (1024 * 1024)

    return None

def extract(pattern, text):
    match = re.search(pattern,text)
    if match:
        return match.group(1)
    return None

# =====================================================
# PARSER FILE WRK
# =====================================================

def parse_wrk_file(filepath):

    with open(filepath, "r") as f:
        text = f.read()

    filename = os.path.basename(filepath)

    config = os.path.basename(os.path.dirname(os.path.dirname(filepath)))

    return {
        "Configuration": config,

        "Threads": int(
            extract(
                r"(\d+)\s+threads and",
                text
            )
            or 0
        ),

        "Connections": int(
            extract(
                r"and\s+(\d+)\s+connections",
                text
            )
            or 0
        ),

        # --------------------------
        # LATENCY
        # --------------------------

        "Avg_Latency_ms":
            parse_time_to_ms(
                extract(
                    r"Latency\s+([\d\.]+[a-z]+)",
                    text
                )
            ),

        "Max_Latency_ms":
            parse_time_to_ms(
                extract(
                    r"Latency\s+[\d\.]+[a-z]+\s+[\d\.]+[a-z]+\s+([\d\.]+[a-z]+)",
                    text
                )
            ),

        "P50_ms":
            parse_time_to_ms(
                extract(
                    r"50%\s+([\d\.]+[a-z]+)",
                    text
                )
            ),

        "P75_ms":
            parse_time_to_ms(
                extract(
                    r"75%\s+([\d\.]+[a-z]+)",
                    text
                )
            ),

        "P90_ms":
            parse_time_to_ms(
                extract(
                    r"90%\s+([\d\.]+[a-z]+)",
                    text
                )
            ),

        "P99_ms":
            parse_time_to_ms(
                extract(
                    r"99%\s+([\d\.]+[a-z]+)",
                    text
                )
            ),

        # --------------------------
        # THROUGHPUT
        # --------------------------

        "Total_Requests": int(
            extract(
                r"(\d+)\s+requests in",
                text
            )
            or 0
        ),

        "Requests_sec": float(
            extract(
                r"Requests/sec:\s+([\d\.]+)",
                text
            )
            or 0
        ),

        "Transfer_MB_sec":
            parse_size_to_mb(
                extract(
                    r"Transfer/sec:\s+([\d\.]+[A-Za-z]+)",
                    text
                )
            ),

        # --------------------------
        # ERRORI
        # --------------------------

        "Socket_connect_errors": int(
            extract(
                r"connect\s+(\d+)",
                text
            )
            or 0
        ),

        "Socket_read_errors": int(
            extract(
                r"read\s+(\d+)",
                text
            )
            or 0
        ),

        "Socket_write_errors": int(
            extract(
                r"write\s+(\d+)",
                text
            )
            or 0
        ),

        "Socket_timeout_errors": int(
            extract(
                r"timeout\s+(\d+)",
                text
            )
            or 0
        )
    }

# =====================================================
# MEDIA RUN
# =====================================================

def process_wrk_results(wrk_pattern, output_dir):
    files = glob.glob(wrk_pattern)

    if not files:
        print("Nessun file WRK trovato")
        return

    results = []

    for file in files:

        print("Analizzo:", file)

        results.append(parse_wrk_file(file))

    df = pd.DataFrame(results)

    for config, group in df.groupby("Configuration"):

        output_folder = os.path.join(output_dir, config, "metrics_csv")

        os.makedirs(output_folder, exist_ok=True)

        # media delle run

        avg = (group.select_dtypes(include="number").mean().round(2).to_frame().T)

        avg.insert(0,"Configuration",config)

        output_file = os.path.join(output_folder, f"wrk_avg_{config}.csv")

        avg.to_csv(output_file, index=False)

        print(f"Creato: {output_file}")

# =====================================================
# MAIN
# =====================================================

if __name__ == "__main__":

    BASE_DIR = "experiments/baseline/workload_test"

    process_wrk_results(
        wrk_pattern= f"{BASE_DIR}/*/raw/wrk*.txt",
        output_dir= BASE_DIR
    )

    print("\nElaborazione WRK completata.")