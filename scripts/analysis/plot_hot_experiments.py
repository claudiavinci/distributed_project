
#!/usr/bin/env python3

import argparse
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

# =====================================
# CONFIGURAZIONE
# =====================================

plt.rcParams.update({
    "font.size": 10,
    "axes.labelsize": 11,
    "legend.fontsize": 9,
    "figure.dpi": 120
})

EXPERIMENTS = {
    "offload": {
        "start": "OFFLOAD_COMMAND_START",
        "end": "DEPLOYMENT_REMOTE_READY:",
        "end_prefix": True,
        "end_last": True,
        "labels": ["Prima", "Migrazione", "Dopo"]
    },
    "return": {
        "start": "RETURN_COMMAND_START",
        "end": "WORKLOADS_LOCAL_READY",
        "end_prefix": False,
        "end_last": False,
        "labels": ["Prima", "Rientro", "Dopo"]
    },
    "fault": {
        "start": "FAULT_COMMAND_START",
        "end": "NODE_RESTARTED",
        "end_prefix": False,
        "end_last": False,
        "labels": ["Prima", "Fault / riavvio", "Dopo"]
    }
}

COLORS = {
    "before": "#3977b7",
    "during": "#d28b27",
    "after": "#368b72"
}

# =====================================
# LETTURA EVENTI
# =====================================


def read_events(path):

    df = pd.read_csv(path)

    if "event" not in df.columns:
        raise ValueError("Colonna 'event' mancante")

    if "epoch_ms" in df.columns:
        df["epoch_ms"] = pd.to_numeric(
            df["epoch_ms"],
            errors="coerce"
        )

    elif "timestamp" in df.columns:
        timestamps = pd.to_datetime(
            df["timestamp"],
            format="%Y-%m-%d %H:%M:%S",
            errors="coerce"
        )

        if timestamps.isna().any():
            raise ValueError(
                "Timestamp non validi nel file eventi"
            )

        # I timestamp sono nell'ora locale del test.
        # Specificare il fuso per convertirli in epoch.
        timestamps = timestamps.dt.tz_localize(
            "Europe/Rome",
            ambiguous="raise",
            nonexistent="raise"
        )

        df["epoch_ms"] = (
            timestamps.astype("datetime64[ns, Europe/Rome]")
            .astype("int64") // 10**6
        )

    else:
        raise ValueError(
            "Manca sia 'epoch_ms' sia 'timestamp'"
        )

    df = df.dropna(subset=["epoch_ms"])
    return df.sort_values("epoch_ms")

def get_event_time(events, name, prefix=False, last=False):

    names = events["event"].astype(str)

    if prefix:
        rows = events[names.str.startswith(name)]
    else:
        rows = events[names == name]

    if rows.empty:
        raise ValueError(f"Evento non trovato: {name}")

    value = rows.iloc[-1 if last else 0]["epoch_ms"]

    return float(value) / 1000


# =====================================
# LETTURA LOCUST
# =====================================

def read_locust(path):
    df = pd.read_csv(path, low_memory=False)
    required = [
        "Timestamp",
        "Name",
        "User Count",
        "Requests/s",
        "Failures/s",
        "95%",
        "99%",
        "Total Request Count",
        "Total Failure Count",
        "Total Average Response Time"
    ]

    missing = [col for col in required if col not in df.columns]

    if missing:
        raise ValueError(f"Colonne Locust mancanti: {missing}")
    
    # Considera tutte le richieste aggregate
    df = df[df["Name"] == "Aggregated"].copy()

    if df.empty:
        raise ValueError("Nessuna riga Aggregated nello storico")

    for col in required:
        if col != "Name":
            df[col] = pd.to_numeric(
                df[col],
                errors="coerce"
            )

    df = df.dropna(subset=["Timestamp"])

    df = df.sort_values("Timestamp")

    df = df.drop_duplicates(subset=["Timestamp"], keep="last")

    return df.reset_index(drop=True)


# =====================================
# METRICHE PER INTERVALLO
# =====================================

def calculate_interval_metrics(df):

    df = df.copy()

    requests = df["Total Request Count"]
    failures = df["Total Failure Count"]
    mean = df["Total Average Response Time"]

    # Incrementi dei contatori cumulativi
    df["delta_requests"] = requests.diff()
    df["delta_failures"] = failures.diff()

    # Durata effettiva tra due campioni
    df["delta_time"] = df["Timestamp"].diff()

    # Somma cumulativa dei tempi di risposta
    cumulative_time = requests * mean

    df["delta_response_time"] = (cumulative_time.diff())

    # Scarta intervalli non validi
    valid = (
        (df["delta_time"] > 0) &
        (df["delta_requests"] > 0) &
        (df["delta_failures"] >= 0) &
        (df["delta_failures"] <= df["delta_requests"])
    )

    # Media delle richieste del singolo intervallo
    df["interval_mean_ms"] = np.where(valid, df["delta_response_time"] / df["delta_requests"], np.nan)

    # Percentuale di errori per intervallo
    df["interval_failure_pct"] = np.where(valid, 100 * df["delta_failures"] / df["delta_requests"], np.nan)

    # RPS ricostruiti dai contatori
    df["interval_rps"] = np.where(valid, df["delta_requests"] / df["delta_time"], np.nan)

    # I percentili sono cumulativi.
    # Gli zeri iniziali non rappresentano latenze valide.
    for col in ["95%", "99%"]:
        df[col] = df[col].where((requests > 0) & (df[col] > 0), np.nan)

    return df

# =====================================
# GRAFICI
# =====================================

def save_plot(fig, output_dir, filename):

    fig.tight_layout()
    fig.savefig(
        output_dir / f"{filename}.png",
        dpi=300,
        bbox_inches="tight"
    )
    plt.close(fig)
    print(f"Generato: {filename}.png")


def create_axes(duration, transition_start, transition_end, start_label, end_label):

    fig, ax = plt.subplots(figsize=(11, 4.5))

    ax.axvspan(
        0,
        transition_start,
        color=COLORS["before"],
        alpha=0.07
    )

    ax.axvspan(
        transition_start,
        transition_end,
        color=COLORS["during"],
        alpha=0.12
    )

    ax.axvspan(
        transition_end,
        duration,
        color=COLORS["after"],
        alpha=0.07
    )

    ax.axvline(
        transition_start,
        color=COLORS["during"],
        linestyle="--",
        linewidth=1.3,
        label=start_label
    )

    ax.axvline(
        transition_end,
        color=COLORS["after"],
        linestyle="--",
        linewidth=1.3,
        label=end_label
    )

    ax.set_xlim(0, duration)
    ax.set_xlabel("Tempo da LOCUST_START (s)")
    ax.grid(alpha=0.25)

    return fig, ax


def plot_throughput(df, axes_args, output_dir):

    fig, ax = create_axes(*axes_args)

    ax.plot(
        df["relative_time"],
        df["Requests/s"],
        color="#2766a6",
        linewidth=1.5,
        label="Throughput"
    )

    ax.set_ylabel("Throughput (req/s)")
    ax.legend(fontsize=8)
    save_plot(fig, output_dir, "throughput")

def plot_latency(df, axes_args, output_dir):

    fig, ax = create_axes(*axes_args)

    ax.plot(
        df["relative_time"],
        df["interval_mean_ms"],
        color="#2766a6",
        linewidth=1.4,
        label="Media"
    )

    ax.set_ylabel("Latency (ms)")
    ax.legend(fontsize=8)

    save_plot(fig, output_dir, "latency")

def plot_latency_percentiles(df, axes_args, output_dir):

    fig, ax = create_axes(*axes_args)

    ax.plot(
        df["relative_time"],
        df["95%"],
        color="#d28b27",
        linewidth=1.4,
        label="P95"
    )

    ax.plot(
        df["relative_time"],
        df["99%"],
        color="#a73748",
        linewidth=1.4,
        label="P99"
    )

    ax.set_ylabel("Latency (ms)")
    ax.legend(fontsize=8)

    save_plot(fig, output_dir, "latency_percentiles")

def plot_failure_rate(df, axes_args, output_dir):

    fig, ax = create_axes(*axes_args)
    
    ax.plot(
        df["relative_time"],
        df["interval_failure_pct"],
        color="#ad3e45",
        linewidth=1.5,
        label="Failure rate"
    )

    ax.set_ylabel("Failure Rate (%)")
    ax.set_ylim(bottom=0, top=100)
    ax.legend(fontsize=8)
    save_plot(fig, output_dir, "failure_rate")


# =====================================
# MAIN
# =====================================

def main():

    parser = argparse.ArgumentParser(
        description=(
            "Analisi Locust per hot offloading, "
            "unoffloading e fault test"
        )
    )

    parser.add_argument(
        "--type",
        required=True,
        choices=EXPERIMENTS.keys()
    )

    parser.add_argument(
        "--history",
        required=True,
        type=Path
    )

    parser.add_argument(
        "--events",
        required=True,
        type=Path
    )

    parser.add_argument(
        "--output-dir",
        required=True,
        type=Path
    )

    parser.add_argument(
        "--plots-dir",
        required=True,
        type=Path
    )

    parser.add_argument(
        "--transition-start",
        default=None,
        help="Override evento di inizio transizione"
    )

    parser.add_argument(
        "--transition-end",
        default=None,
        help="Override evento di fine transizione"
    )

    args = parser.parse_args()

    output_dir = args.output_dir
    plots_dir = args.plots_dir

    output_dir.mkdir(parents=True, exist_ok=True)
    plots_dir.mkdir(parents=True, exist_ok=True)

    config = EXPERIMENTS[args.type]

    # Lettura
    events = read_events(args.events)
    df = read_locust(args.history)

    # Timestamp esperimento
    start = get_event_time(events, "LOCUST_START")

    end = get_event_time(events, "LOCUST_END")

    start_event = (args.transition_start or config["start"])

    end_event = (args.transition_end or config["end"])

    t1 = get_event_time(events, start_event)

    t2 = get_event_time(
        events,
        end_event,
        prefix=(
            config["end_prefix"]
            if args.transition_end is None
            else False
        ),
        last=(
            config["end_last"]
            if args.transition_end is None
            else False
        )
    )

    if not start < t1 < t2 < end:
        raise ValueError(
            "Ordine temporale degli eventi non valido"
        )

    # Filtra la durata del test
    df = df[(df["Timestamp"] >= start) & (df["Timestamp"] <= end)].copy()

    if df.empty:
        raise ValueError("Nessun campione Locust nell'intervallo")

    df = calculate_interval_metrics(df)

    df["relative_time"] = (df["Timestamp"] - start)

    duration = end - start

    axes_args = (
        duration,
        t1 - start,
        t2 - start,
        start_event,
        end_event
    )

    # Grafici
    plot_throughput(df, axes_args, plots_dir)

    plot_latency(df, axes_args, plots_dir)
    plot_latency_percentiles(df, axes_args, plots_dir)

    plot_failure_rate(df, axes_args, plots_dir)
    print(f"Output: {output_dir}")


if __name__ == "__main__":
    main()
