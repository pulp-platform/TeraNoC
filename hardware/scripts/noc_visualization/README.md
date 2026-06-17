# NoC Traffic Visualization

Visualize per-link, per-channel, per-timeslice NoC traffic using [vis4mesh](https://github.com/ueqri/vis4mesh).

## Prerequisites

- vis4mesh built at `/usr/scratch/larain12/zexifu/teranoc_visual/vis4mesh` (or your own build)
- Python 3 with standard library

## Quick Start

### 1. Run simulation (trace is generated automatically)

The testbench includes `tb_noc_visualization.svh` which taps every FlooNoC router port and writes a CSV trace to `<buildpath>/v4m_out/trace_events.csv`.

```bash
cd hardware
make simc config=mempool_spatz4_fpu app=apps/spatz_apps/sp-fmatmul-opt-burst-merge buildpath=build_vis
```

### 2. Convert CSV to vis4mesh format

```bash
# For mempool_spatz4_fpu (2x2 mesh, 16 tiles/group, 0 narrow + 2 wide req + 2 resp channels):
python3 scripts/noc_visualization/gen_v4m_from_csv.py \
    build_vis/v4m_out/trace_events.csv \
    build_vis/vis4mesh_out \
    --W 2 --H 2 \
    --tiles-per-group 16 \
    --narrow-req-ch 0 --wide-req-ch 2 --resp-ch 2 \
    --cycles-per-slice 10 --debug

# For terapool_spatz4_fpu (4x4 mesh):
python3 scripts/noc_visualization/gen_v4m_from_csv.py \
    build_vis/v4m_out/trace_events.csv \
    build_vis/vis4mesh_out \
    --W 4 --H 4 \
    --tiles-per-group 16 \
    --narrow-req-ch 0 --wide-req-ch 2 --resp-ch 2 \
    --cycles-per-slice 10 --debug
```

Or use the Makefile target (uses default config dimensions):
```bash
make noc-vis buildpath=build_vis config=mempool_spatz4_fpu
```

### 3. View in browser

#### Option A: Local (browser and data on the same machine)

```bash
cd /usr/scratch/larain12/zexifu/teranoc_visual/vis4mesh/dist
python3 -m http.server 8000
```

Open `http://localhost:8000`, click the upload button (top-left), and select the `build_vis/vis4mesh_out/` **directory**.

#### Option B: Remote (data on fenga1, browser on larain9)

If your VNC/Chrome is on larain9 but simulation data is on fenga1, serve directly from fenga1 to avoid slow cross-machine file uploads.

**Step 1**: On **fenga1**, symlink the vis data into the served directory:
```bash
ln -sf /usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware/build_vis/vis4mesh_out \
       /usr/scratch/larain12/zexifu/teranoc_visual/vis4mesh/dist/visdata_current
```

**Step 2**: On **fenga1**, start the HTTP server (bind to all interfaces):
```bash
cd /usr/scratch/larain12/zexifu/teranoc_visual/vis4mesh/dist
python3 -m http.server 8000 --bind 0.0.0.0
```

**Step 3**: On **larain9**, open Chrome and go to:
```
http://fenga1:8000
```

**Step 4**: Click the upload button and select the `visdata_current` directory. The browser fetches all data from fenga1's HTTP server — no bulk transfer between machines.

> **Tip**: To update the visualization after a new simulation, just re-run step 1 (update the symlink) and refresh the browser. No need to restart the server.

> **Tip**: To change the port (e.g. if 8000 is in use), use `python3 -m http.server 9000 --bind 0.0.0.0` and open `http://fenga1:9000`.

## Channel Mapping

The RTL tracer assigns `router_id` as the channel index. For `mempool_spatz4_fpu` baseline config (0 narrow, 2 rdwr, 2 resp channels per tile, 16 tiles per group):

| Channel Range | Type | Description |
|---|---|---|
| 0-31 | Wide Request (RDWR) | Load/store requests to remote groups |
| 32-63 | Response | Data/acks returning from remote groups |

Within each range: `channel = tile * channels_per_tile + channel_index`.

When using `--tiles-per-group`, the converter auto-generates:
- Descriptive labels: `WideReq_T0_C0`, `Resp_T5_C1`, etc.
- Group toggle buttons in vis4mesh: **"Wide Req (32)"** and **"Response (32)"** for one-click filtering

## Converter Options

```
gen_v4m_from_csv.py <csv> <outdir> --W <width> --H <height> [options]

Required:
  csv                   CSV file from RTL tracer
  outdir                Output directory for vis4mesh data
  --W                   Mesh width (num_x)
  --H                   Mesh height (num_groups / num_x)

Channel grouping (enables labeled toggle buttons):
  --tiles-per-group N   Tiles per group (e.g. 16)
  --narrow-req-ch N     Narrow (read-only) req channels per tile (default: 0)
  --wide-req-ch N       Wide (read-write) req channels per tile (default: 2)
  --resp-ch N           Response channels per tile (default: 2)

Other:
  --cycles-per-slice N  Cycles per timeslice (default: 10)
  --num-hop-units N     Hop distance buckets (default: 4)
  --debug               Print layout and stride info
  --pretty              Pretty-print JSON (default: on)
```

## Traffic Analysis Scripts

### Link Balance Summary (`analyze_link_balance.py`)

Shows per-node-pair, per-timeslice port balance (port 0 vs port 1) for both WideReq and Resp. Flags timeslices where balance exceeds a threshold.

```bash
# Summary for the benchmark computation phase (cycles 6000-22000):
python3 scripts/noc_visualization/analyze_link_balance.py \
    build_vis/v4m_out/trace_events.csv \
    --W 2 --H 2 --tiles-per-group 16 --wide-req-ch 2 --resp-ch 2 \
    --slice-cycles 1000 --start-cycle 6000 --end-cycle 22000 \
    --threshold 55

# Only show imbalanced timeslices:
python3 scripts/noc_visualization/analyze_link_balance.py \
    build_vis/v4m_out/trace_events.csv \
    --W 2 --H 2 --tiles-per-group 16 --wide-req-ch 2 --resp-ch 2 \
    --slice-cycles 1000 --start-cycle 6000 --end-cycle 22000 \
    --threshold 55 --summary-only
```

Options:
- `--slice-cycles N` — timeslice width in cycles (default: 1000)
- `--start-cycle N` / `--end-cycle N` — filter to a cycle range (use benchmark start/end)
- `--threshold N` — flag timeslices where any port exceeds N% (default: 60)
- `--summary-only` — only print flagged (imbalanced) timeslices

### Per-Link Detail Report (`gen_link_detail_report.py`)

Shows traffic on **every individual link** (16 tiles × 2 ports = 32 links) for each node pair direction, per timeslice. Useful for identifying which specific tiles or ports are over/under-utilized.

```bash
# Full report for all node pairs, save to file:
python3 scripts/noc_visualization/gen_link_detail_report.py \
    build_vis/v4m_out/trace_events.csv \
    --W 2 --H 2 --tiles-per-group 16 --wide-req-ch 2 --resp-ch 2 \
    --slice-cycles 1000 --start-cycle 6000 --end-cycle 22000 \
    -o build_vis/link_report.txt

# Single node pair to stdout:
python3 scripts/noc_visualization/gen_link_detail_report.py \
    build_vis/v4m_out/trace_events.csv \
    --W 2 --H 2 --tiles-per-group 16 --wide-req-ch 2 --resp-ch 2 \
    --slice-cycles 1000 --start-cycle 6000 --end-cycle 22000 \
    --node-pair 0-1

# For terapool (4x4 mesh):
python3 scripts/noc_visualization/gen_link_detail_report.py \
    build_vis/v4m_out/trace_events.csv \
    --W 4 --H 4 --tiles-per-group 16 --wide-req-ch 2 --resp-ch 2 \
    --slice-cycles 1000 -o build_vis/link_report.txt
```

Output format — one table per node pair per link type:
```
=== G0->G1 WideReq: 32 links (16 tiles x 2 ports) ===
     Period  T00p0 T00p1  T01p0 T01p1  ...  T15p0 T15p1   TOTAL p0 p1 balance
  6000-7000     21    33     33    22  ...     19    26     456  456 429 51%/49%
  7000-8000     29    19     26    28  ...     25    24     821  405 416 49%/51%
```

Options:
- `--node-pair A-B` — filter to a single direction (e.g., `0-1` for G0→G1)
- `-o FILE` — save to file instead of stdout (recommended for full reports)

## RTL Tracer Configuration

The tracer (`hardware/tb/tb_noc_visualization.svh`) can be configured via defines before the include:

```systemverilog
`define V4M_SLICE_CYCLES 1    // Cycles per timeslice (default: 1)
`define V4M_OUT_DIR "v4m_out" // Output directory (default: "v4m_out")
`define V4M_OUT_FILE "trace_events.csv" // Output filename
```

## CSV Format

The tracer produces a CSV with one row per active router handshake per cycle:

```
slice,edge_src,edge_dst,tt,mt,ch,flits,pkt_src,pkt_dst
```

| Column | Description |
|--------|-------------|
| slice | Timeslice index (cycle / V4M_SLICE_CYCLES) |
| edge_src | Current hop source group (y*W+x) |
| edge_dst | Current hop destination group |
| tt | Transfer type: 0=TX, 1=Relay, 2=RX, 3=Peripheral |
| mt | Message type: 0=DataReadyRsp, 1=ReadReq, 2=WriteDoneRsp, 3=WriteReq |
| ch | Physical channel (router_id within group) |
| flits | Flit count (1 per handshake) |
| pkt_src | Packet origin group |
| pkt_dst | Packet destination group |
