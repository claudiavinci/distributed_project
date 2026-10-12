#!/usr/bin/env python3

import os
import glob
import re
import argparse
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
    match = re.search(pattern, text)
    if match:
        return match.group(1)
    return None

# =====================================================
# PARSER WRK
# =====================================================

def parse_wrk_file(filepath, configuration):

    with open(filepath, "r") as f:
        text = f.read()

    return {

        "Configuration": configuration,

        # --------------------------
        # CONFIGURAZIONE TEST
        # --------------------------

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
# ELABORAZIONE RISULTATI
# =====================================================

def process_wrk_results(
        runs_dir,
        output_dir,
        configuration
):
    pattern = os.path.join(
        runs_dir,
        "wrk*.txt"
    )

    files = sorted(
        glob.glob(pattern)
    )

    if not files:
        print("Nessun file WRK trovato:")
        print(pattern)
        return

    results = []

    for file in files:
        print("Analizzo:", file)
        results.append(
            parse_wrk_file(
                file,
                configuration
            )
        )

    df = pd.DataFrame(results)

    os.makedirs(
        output_dir,
        exist_ok=True
    )

    # --------------------------
    # MEDIA DELLE RUN
    # --------------------------

    avg = (
        df
        .select_dtypes(include="number")
        .mean()
        .round(2)
        .to_frame()
        .T
    )

    avg.insert(
        0,
        "Configuration",
        configuration
    )

    output_file = os.path.join(
        output_dir,
        f"wrk_avg_{configuration}.csv"
    )

    avg.to_csv(
        output_file,
        index=False
    )

    print()
    print("Creato:")
    print(output_file)

# =====================================================
# MAIN
# =====================================================

if __name__ == "__main__":

    parser = argparse.ArgumentParser(
        description="Analisi risultati WRK"
    )

    parser.add_argument(
        "--runs-dir",
        required=True,
        help="Cartella contenente file wrk"
    )

    parser.add_argument(
        "--output-dir",
        required=True,
        help="Cartella output CSV"
    )

    parser.add_argument(
        "--configuration",
        required=True,
        help="Configurazione esperimento (es. c100)"
    )

    args = parser.parse_args()

    process_wrk_results(
        runs_dir=args.runs_dir,
        output_dir=args.output_dir,
        configuration=args.configuration
    )

    print()
    print("Elaborazione WRK completata.")