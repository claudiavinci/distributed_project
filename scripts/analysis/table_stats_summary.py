
#!/usr/bin/env python3

import argparse
from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.font_manager as fm

# =====================================
# ARGOMENTI
# =====================================

parser = argparse.ArgumentParser(
    description="Genera tabella PNG delle metriche Locust"
)

parser.add_argument(
    "csv_file",
    help="CSV di input"
)

parser.add_argument(
    "--output",
    default="stats_table.png",
    help="File PNG di output"
)

args = parser.parse_args()

output_path = Path(args.output)
output_path.parent.mkdir(parents=True, exist_ok=True)

# =====================================
# CONFIGURAZIONE STILE
# =====================================

FONT_NAME = "Proxima Nova"

HEADER_COLOR = "#a77f28"
CELL_COLOR = "#fafafa"
BORDER_COLOR = "#a77f28"
TEXT_COLOR = "#222222"

FONT_SIZE = 9
CELL_PADDING = 0.35
CELL_HEIGHT = 0.55
BORDER_WIDTH = 1.2
DPI = 300

# Verifica font
available_fonts = {
    font.name for font in fm.fontManager.ttflist
}

if FONT_NAME not in available_fonts:
    print(
        f"Font '{FONT_NAME}' non trovato. "
        "Uso DejaVu Sans."
    )
    FONT_NAME = "DejaVu Sans"

plt.rcParams["font.family"] = FONT_NAME

# =====================================
# LETTURA CSV
# =====================================

df = pd.read_csv(args.csv_file)
df = df.sort_values("users")

# =====================================
# FORMATTAZIONE METRICHE
# =====================================

def fmt(row, metric):
    mean = row[f"{metric}_mean"]
    std = row[f"{metric}_std"]

    return f"{mean:.2f}\n± {std:.2f}"


rows = []

for _, row in df.iterrows():
    rows.append([
        str(int(row["users"])),
        fmt(row, "requests"),
        fmt(row, "requests_per_sec"),
        fmt(row, "failures"),
        fmt(row, "failure_rate_pct"),
        fmt(row, "latency_avg_ms"),
        fmt(row, "latency_p90_ms"),
        fmt(row, "latency_p95_ms"),
        fmt(row, "latency_p99_ms"),
        fmt(row, "latency_min_ms"),
        fmt(row, "latency_max_ms")
    ])

columns = [
    "Users",
    "Requests",
    "Req/s",
    "Failures",
    "Failure rate\n(%)",
    "Latency\n(ms)",
    "Latency P90\n(ms)",
    "Latency P95\n(ms)",
    "Latency P99\n(ms)",
    "Latency min\n(ms)",
    "Latency max\n(ms)"
]

# =====================================
# CREAZIONE TABELLA
# =====================================

# Altezza proporzionata al numero di righe
fig_height = (len(rows) + 1) * CELL_HEIGHT

# Larghezza iniziale per il calcolo delle celle
fig_width = 16

fig, ax = plt.subplots(
    figsize=(fig_width, fig_height)
)

fig.patch.set_facecolor("white")
ax.axis("off")

fig.subplots_adjust(
    left=0,
    right=1,
    top=1,
    bottom=0
)

table = ax.table(
    cellText=rows,
    colLabels=columns,
    cellLoc="center",
    loc="center"
)

table.auto_set_font_size(False)
table.set_fontsize(FONT_SIZE)

# =====================================
# STILE TABELLA
# =====================================

for (r, c), cell in table.get_celld().items():

    # Padding orizzontale
    cell.PAD = CELL_PADDING

    # Bordi
    cell.set_edgecolor(BORDER_COLOR)
    cell.set_linewidth(BORDER_WIDTH)

    # Font
    cell.get_text().set_fontfamily(FONT_NAME)

    if r == 0:
        cell.set_facecolor(HEADER_COLOR)
        cell.set_text_props(
            weight="bold",
            color="white"
        )
    else:
        cell.set_facecolor(CELL_COLOR)
        cell.set_text_props(color=TEXT_COLOR)

        if c == 0:
            cell.set_text_props(weight="bold")

# =====================================
# DIMENSIONI CELLE
# =====================================

# Larghezza automatica con padding
table.auto_set_column_width(
    col=list(range(len(columns)))
)

# Padding verticale
for (r, c), cell in table.get_celld().items():
    cell.set_height(CELL_HEIGHT / fig_height)

# Calcola le dimensioni effettive
fig.canvas.draw()

# =====================================
# SALVATAGGIO
# =====================================

fig.savefig(
    output_path,
    dpi=DPI,
    bbox_inches="tight",
    pad_inches=0.05,
    facecolor="white"
)

plt.close(fig)

print(f"Tabella PNG salvata in: {output_path}")