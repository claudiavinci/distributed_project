
#!/usr/bin/env python3

import argparse
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

# =====================================
# CONFIGURAZIONE GRAFICI
# =====================================

plt.rcParams.update({
    "font.size": 10,
    "axes.labelsize": 11,
    "legend.fontsize": 9,
    "figure.dpi": 120
})

# =====================================
# FUNZIONI COMUNI
# =====================================

def save_plot(fig, output_dir, filename):
    output_dir.mkdir(parents=True, exist_ok=True)

    fig.tight_layout()
    fig.savefig(
        output_dir / f"{filename}.png",
        dpi=300,
        bbox_inches="tight"
    )
    plt.close(fig)
    print(f"Generato: {filename}")


def plot_metric(df, metrics, ylabel, output_dir,
                filename, baseline=None):
    """Grafico a linee con confronto opzionale baseline."""

    df = df.sort_values("users")

    if baseline is not None:
        baseline = baseline.sort_values("users")

    fig, ax = plt.subplots(figsize=(8, 4.5))

    for mean_col, std_col, label in metrics:

        # Configurazione corrente
        line = ax.errorbar(
            df["users"],
            df[mean_col],
            yerr=df[std_col],
            marker="o",
            linestyle="-",
            linewidth=2,
            capsize=4,
            label=label
        )

        # Riutilizza esattamente lo stesso colore
        color = line.lines[0].get_color()

        # Baseline
        if baseline is not None:
            ax.errorbar(
                baseline["users"],
                baseline[mean_col],
                yerr=baseline[std_col],
                color=color,
                linestyle="--",
                marker=None,
                linewidth=1.8,
                capsize=3,
                alpha=0.8,
                label=f"{label} (baseline)"
            )

    ax.set_xlabel("Users")
    ax.set_ylabel(ylabel)
    ax.set_xticks(sorted(df["users"].unique()))
    ax.grid(True, linestyle="--", alpha=0.3)
    ax.legend()

    save_plot(fig, output_dir, filename)


# =====================================
# METRICHE APPLICATIVE (LOCUST)
# =====================================

def plot_stats(csv_path, output_dir, baseline_path=None):

    df = pd.read_csv(csv_path)

    baseline = (
        pd.read_csv(baseline_path)
        if baseline_path else None
    )

    plot_metric(
        df,
        [
            (
                "requests_per_sec_mean",
                "requests_per_sec_std",
                "Throughput"
            )
        ],
        "Throughput (req/s)",
        output_dir,
        "throughput",
        baseline
    )

    plot_metric(
        df,
        [
            (
                "latency_avg_ms_mean",
                "latency_avg_ms_std",
                "Media"
            ),
            (
                "latency_p90_ms_mean",
                "latency_p90_ms_std",
                "P90"
            ),
            (
                "latency_p95_ms_mean",
                "latency_p95_ms_std",
                "P95"
            ),
            (
                "latency_p99_ms_mean",
                "latency_p99_ms_std",
                "P99"
            )
        ],
        "Latency (ms)",
        output_dir,
        "latency",
        baseline
    )


# =====================================
# METRICHE DEI NODI
# =====================================

def plot_nodes(csv_path, output_dir, baseline_path=None):

    df = pd.read_csv(csv_path)

    baseline = (
        pd.read_csv(baseline_path)
        if baseline_path else None
    )

    # Normalizza i nomi dei nodi
    df["node"] = df["node"].fillna("patient-cloud")

    if baseline is not None:
        baseline["node"] = baseline["node"].fillna("patient-cloud")

    metrics = [
        (
            "cpu_avg_%_mean",
            "cpu_avg_%_std",
            "Mean CPU usage (%)",
            "nodes_cpu"
        ),
        (
            "memory_avg_%_mean",
            "memory_avg_%_std",
            "Mean memory usage (%)",
            "nodes_memory"
        )
    ]

    for mean_col, std_col, ylabel, filename in metrics:

        fig, ax = plt.subplots(figsize=(8, 4.5))

        for node, group in df.groupby("node"):

            group = group.sort_values("users")

            # Configurazione corrente
            line = ax.errorbar(
                group["users"],
                group[mean_col],
                yerr=group[std_col],
                marker="o",
                linestyle="-",
                linewidth=2,
                capsize=4,
                label=node
            )

            color = line.lines[0].get_color()

            # Baseline dello stesso nodo
            if baseline is not None:

                base_group = baseline[
                    baseline["node"] == node
                ].sort_values("users")

                if not base_group.empty:
                    ax.errorbar(
                        base_group["users"],
                        base_group[mean_col],
                        yerr=base_group[std_col],
                        color=color,
                        linestyle="--",
                        marker=None,
                        linewidth=1.8,
                        capsize=3,
                        alpha=0.8,
                        label=f"{node} (baseline)"
                    )

        ax.set_xlabel("Users")
        ax.set_ylabel(ylabel)
        ax.set_xticks(sorted(df["users"].unique()))
        ax.grid(True, linestyle="--", alpha=0.3)
        ax.legend()

        save_plot(fig, output_dir, filename)


# =====================================
# METRICHE DEI POD
# =====================================

def plot_pods(csv_path, output_dir):

    df = pd.read_csv(csv_path)

    # Elimina il suffisso Kubernetes del nome pod
    df["service"] = df["pod"].str.replace(
        r"-[a-z0-9]+-[a-z0-9]+$",
        "",
        regex=True
    )

    # Esclude il generatore di carico
    df = df[df["service"] != "locust-tester"]

    users_levels = sorted(df["users"].unique())
    order = sorted(df["service"].unique())

    metrics = [
        (
            "cpu_avg_millicores_mean",
            "cpu_avg_millicores_std",
            "Mean CPU usage (mCPU)",
            "pods_cpu"
        ),
        (
            "memory_avg_MiB_mean",
            "memory_avg_MiB_std",
            "Mean Memory usage (MiB)",
            "pods_memory"
        )
    ]

    for mean_col, std_col, ylabel, filename in metrics:

        fig, ax = plt.subplots(figsize=(13, 5.5))

        x = np.arange(len(order))
        width = 0.8 / len(users_levels)

        for i, users in enumerate(users_levels):

            data = (
                df[df["users"] == users]
                .set_index("service")
                .reindex(order)
            )

            offset = (
                i - (len(users_levels) - 1) / 2
            ) * width

            ax.bar(
                x + offset,
                data[mean_col],
                width,
                yerr=data[std_col],
                capsize=2,
                label=f"{users} utenti"
            )

        ax.set_xlabel("Microservices")
        ax.set_ylabel(ylabel)
        ax.set_xticks(x)
        ax.set_xticklabels(
            order,
            rotation=35,
            ha="right"
        )

        ax.grid(
            axis="y",
            linestyle="--",
            alpha=0.3
        )

        ax.set_axisbelow(True)
        ax.legend(title="Carico")

        save_plot(fig, output_dir, filename)


# =====================================
# MAIN
# =====================================

def main():

    parser = argparse.ArgumentParser(
        description="Generazione grafici esperimenti Kubernetes/Liqo"
    )

    parser.add_argument("--stats", type=Path)
    parser.add_argument("--nodes", type=Path)
    parser.add_argument("--pods", type=Path)

    parser.add_argument("--baseline-stats", type=Path)
    parser.add_argument("--baseline-nodes", type=Path)

    parser.add_argument(
        "--output",
        type=Path,
        required=True
    )

    args = parser.parse_args()

    if args.stats:
        plot_stats(
            args.stats,
            args.output,
            args.baseline_stats
        )

    if args.nodes:
        plot_nodes(
            args.nodes,
            args.output,
            args.baseline_nodes
        )

    if args.pods:
        plot_pods(
            args.pods,
            args.output
        )

    if not any([
        args.stats,
        args.nodes,
        args.pods
    ]):
        parser.error(
            "Specificare almeno un CSV: --stats, --nodes o --pods"
        )


if __name__ == "__main__":
    main()
