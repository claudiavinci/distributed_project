
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
    description="Genera tabella PNG delle metriche dei nodi"
)

parser.add_argument(
    "csv_file",
    help="CSV di input"
)

parser.add_argument(
    "--output",
    default="nodes_table.png",
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

node_order = [
    "consumer-control-plane",
    "consumer-worker",
    "consumer-worker2"
]

df["node"] = pd.Categorical(
    df["node"],
    categories=node_order,
    ordered=True
)

df = df.sort_values(["users", "node"])

# =====================================
# FORMATTAZIONE METRICHE
# =====================================

def fmt(row, metric):

    mean = row[f"{metric}_mean"]
    std = row[f"{metric}_std"]

    return f"{mean:.3f}\n± {std:.3f}"


rows = []
user_groups = []

for users, group in df.groupby(
    "users", sort=True, observed=True
):

    start = len(rows) + 1

    for _, row in group.iterrows():

        rows.append([
            "",
            str(row["node"]),
            fmt(row, "cpu_avg_%"),
            fmt(row, "cpu_max_%"),
            fmt(row, "memory_avg_%"),
            fmt(row, "memory_max_%")
        ])

    end = len(rows)

    user_groups.append((users, start, end))

columns = [
    "Users",
    "Node",
    "CPU (%)",
    "CPU max (%)",
    "Memory (%)",
    "Memory max (%)"
]

# =====================================
# CREAZIONE TABELLA
# =====================================

fig_height = (len(rows) + 1) * CELL_HEIGHT
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

# =====================================
# UNIONE CELLE USERS
# =====================================

for users, start, end in user_groups:

    # Riga centrale del gruppo
    middle = (start + end) // 2

    table[(middle, 0)].get_text().set_text(str(users))
    table[(middle, 0)].get_text().set_weight("bold")

    # Elimina i bordi orizzontali interni
    for r in range(start, end + 1):

        cell = table[(r, 0)]

        if start == end:
            cell.visible_edges = "LTRB"
        elif r == start:
            cell.visible_edges = "TLR"
        elif r == end:
            cell.visible_edges = "BLR"
        else:
            cell.visible_edges = "LR"

# =====================================
# DIMENSIONI CELLE
# =====================================

# Larghezza automatica in base al contenuto
table.auto_set_column_width(
    col=list(range(len(columns)))
)

# Altezza uniforme delle celle
for (r, c), cell in table.get_celld().items():
    cell.set_height(CELL_HEIGHT / fig_height)

# Calcola le dimensioni effettive
fig.canvas.draw()

# =====================================
# SALVATAGGIO PNG
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
