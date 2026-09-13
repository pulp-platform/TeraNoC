# Simulation trace dashboard

Use **`python3 sim_dashboard/generate.py`** for all inputs. It generates one
**offline HTML file** with a full-run overview and selectable detail from RTL
transcripts and optional structured telemetry. All new source, tests, generated
copies and outputs live in this folder.
Instrumentation uses a private testbench copy; the probe does not change RTL behavior.
VCS is the preferred RTL simulator. The campaign scripts build private images
and preload private ELFs to keep concurrent runs isolated.

Python 3.9+ standard library is enough to generate a dashboard. Open the result
in a current Chrome, Edge or Firefox with `DecompressionStream` support. The HTML
contains its JavaScript, styles and compressed data; it makes no network requests.

## Existing RTL logs

From the repository root:

```sh
python3 sim_dashboard/generate.py \
  --transcript hardware/hashfix_hf_4x4_fp16_ks2_16x128x4096/transcript \
  --mesh 4x4 --shape 16x128x4096 --precision fp16 \
  --peaks roofline/peaks/terapool_spatz4_fpu.json \
  --out sim_dashboard/output/rtl_4x4.html
```

`--mesh` is **x by y**, with `group = x * NumY + y`. Rectangular meshes work.
`--shape` is **M by N by P**, where N is the reduction dimension. The script
reads `The execution took ... cycles` and `[REPEAT] r=...` where present; use
`--cycles` (per pass) and `--repeat` to supply values absent from old logs.
Do not supply cycles from another run or infer a successful result from exit code.

`--period` is the legacy FPU/LP sampling period (default 1000). `--window` sets
the display window. The generator never splits or interpolates aggregate counts.
A source window crossing a display boundary is assigned by end cycle and its
actual interval is retained. Prefer aligned, equal probe periods for correlation.
Missing periods stay missing. Unclassified legacy counters are retained when
viewing benchmark FPU data and identified by their original phase in source rows.

Read the actual build settings when selecting `--peaks`; the same mesh can have
different FPU counts, ports and bandwidth. The generator rejects explicit geometry
mismatches, but cannot recover every build override from a transcript. Existing
peak tables and `roofline/peaks.py` remain the source of ceiling calculations.

To enable the modeled hash comparison, make a run manifest based on
`examples/manifest.json` and add `--manifest <your-file>`. The example settings
are illustrative, **not recovered facts about the example transcript**. Record
actual runtime CSR settings, not just compile defaults. Store your manifests in
`sim_dashboard/output/` or another directory you choose.

## Views

- **Compute & progress:** overall and selectable group FPU lines, mesh with
  per-group progress, group/time heatmap. All views share phase, group and time.
- **MSHR & L1 banks:** group occupancy, peak/full counts, individual entry
  occupancy/cached/held fractions and end-of-window state, bank/time activity,
  plus existing BP pipeline/tile-bank pressure.
- **L1 NoC:** directed mesh links, request/response and sub-NoC selection,
  transfer/backpressure views, sub-NoC/time heatmap, legacy endpoint counters.
- **Hash analysis:** current modeled distribution, best legal candidates,
  concurrent bank spread and observed occupancy by MSHR bank when available.
- **Roofline:** compute and selected boundary's bandwidth roof, current run
  point, demand/mesh intensity and measured merge factor. A selected-interval
  point appears only with matching work/byte windows. Missing byte boundaries
  have no invented point.
- **Sources & coverage:** input paths, record counts, definitions/limitations,
  metadata and inspectable current-window records. Export saves the selected
  window together with the selected phase/group (the original rows are retained).

Gray or “unavailable” means the measurement was not recorded. In particular,
`[MSHRG]` pressure is not occupancy; `[BP] bank_req` totals are not per-bank
counts; `[LP]` channel totals are not individual directional sub-NoCs. Existing
`noc_trace/events.csv` is not currently imported: its hop records omit the
sub-NoC index and do not measure backpressure. Use the new probe for these views.

## Exact workload progress

The optional probe counts unmasked vector FMAC instructions **at instruction
completion**, adding `vl - vstart` scalar FMACs per completed instruction. An
fp16 vector element is one FMAC, as is an fp32 element; lane busy cycles are
never converted into work. This is completion-granular, not individual element
retirement timing inside an instruction. Only FMACs issued inside the trace CSR
region are attributed to the benchmark, including their late completions.

Supply `expected_fmac_per_group` in the manifest, with one integer per group.
By default the sum must equal `M * N * P * repetitions`. For kernels that
start with FMUL, set `fmac_reduction_steps` to `N - 1` and use
`M * (N - 1) * P * repetitions`; roofline FLOPs still use `2 * M * N * P`. These must describe the actual
kernel work assignment, including tails and idle groups. Equal division is
valid only after checking that assignment. Without this metadata, completed
FMACs are shown but percentage bars remain unavailable. The current probe
supports the repository's unmasked GEMM scope; masked kernels need mask-aware
counting before their progress can be called exact.

For future software integration, `rtl/dashboard_workload.h` supplies a small
print helper for a workload metadata line. The caller supplies its actual group
work assignment; it does not guess or change the kernel. Transcript parsing
recognizes this line. No existing application has been modified to include it.

## Optional RTL telemetry

Create an instrumented **copy** of the current testbench:

```sh
python3 sim_dashboard/instrument.py \
  --out sim_dashboard/generated/mempool_tb.sv
```

Compile this copy **in place of** `hardware/tb/mempool_tb.sv`, with exactly the
same parameters, packages, defines and include directories as that simulation.
Do not compile both copies of `mempool_tb`. The generated copy preserves paths
to the original testbench includes and adds `rtl/dashboard_probe.svh`.
The probe currently targets the Spatz 2D-mesh hierarchy used by Questa/VCS;
Verilator is explicitly excluded and torus probe integration is not verified.

`--compile-script <existing compile.tcl>` also creates a relocated Questa
compile script beside the copy, replacing only that TB source reference.
Run it from a **new private build directory** with a new `work` library. It
preserves the original build's defines and source dependencies. Keep the
original simulator DPI options and use a private absolute ELF preload path;
this tool never builds or overwrites `software/bin`.

At simulation launch add:

```text
+dashboard_file=/absolute/path/sim_dashboard/output/run.jsonl
+dashboard_period=1000
+dashboard_entries
+dashboard_banks
+dashboard_links
```

FPU, FMAC completion, aggregate MSHR occupancy and remote response payload
counters are recorded whenever `dashboard_file` is supplied. Entry, bank and
link detail are individually opt-in, to limit volume and simulator overhead.
The probe flushes on phase changes and at `$finish`, preserving partial windows.
Keep wave dumps enabled for new instrumented runs. A reset after data collection
starts must use a new file/run; cycle resets are not silently stitched together.

Detailed 8x8 telemetry can be large: every enabled physical bank, entry and link
has a record per window, including zeros. Start with a larger period for long
runs or a focused run. Compression reduces the HTML size, but Python and the
browser still hold the decoded dataset in memory. This first version does not
provide disk-backed querying or live tailing.

```sh
python3 sim_dashboard/generate.py \
  --transcript /path/to/run/transcript \
  --telemetry sim_dashboard/output/run.jsonl \
  --manifest sim_dashboard/output/run-manifest.json \
  --peaks /path/to/run-peaks.json \
  --out sim_dashboard/output/run.html \
  --json-out sim_dashboard/output/run-data.json
```

Structured telemetry takes precedence over legacy records of the same identity.
Manifest and explicit CLI values supply missing workload context. See
[SCHEMA.md](SCHEMA.md) for the simulator-independent adapter boundary. GVSOC can
later emit this format or add a parser; no GVSOC adapter is implemented yet.

## Hash and roofline interpretation

The hash model reuses `scripts/mshr_bank_hash_explore.py`'s field-select mapping
and concurrent spread calculation. This integration searches legal candidates
**before selecting the winner**, caps LMUL at m8, preserves the full matrix
stride when sampling steps, accounts for source-group row offsets in prefill,
and uses the single-request hash when a weight load is not burst eligible.

The model is conditional on its work-split and address assumptions. It ranks
concurrent bank spread, not performance or cycle-accurate occupancy. Default
runtime shift bounds are 4..10 and burst bits 0..1; override only to match the
actual implemented configuration. It covers field-select hash mode 3. Optional
`a_base` and `w_base` are byte addresses; absent values assume A at zero and
weights immediately after A. Address modeling is not an ELF-derived validation
of the kernel. `max_steps` bounds exploration cost and is disclosed in the UI.

Roofline follows `roofline/README.md`: one FMAC = two FLOPs; performance uses
`2*M*N*P*repetitions / total_cycles`. Remote receive bytes and serving-bank
response bytes define different intensities. Link-hop byte counts are not
substituted for these payload totals. Legacy windows give **estimated intensity**
when their byte coverage differs from the exact workload region. The point does
not establish numerical correctness; the manifest's correctness status is shown.
The bisection roof is a uniform-traffic model, not a universal traffic-pattern
bound. Select L1 or L2 to inspect their roofs; points require corresponding byte
measurements, which the first probe does not yet export for roofline accounting.

## Verification

```sh
python3 -m pytest -q sim_dashboard/tests/test_metrics.py
python3 sim_dashboard/tests/run_probe.py
```

The second command uses `vcs-2024.09-zr` by default (override `--vcs`);
`--backend questa` retains Questa support. Build outputs and telemetry go beneath
`generated/probe_test`.
It uses a tiny deterministic hierarchy, **not a GEMM performance simulation**.
It exercises real probe code, phase boundaries, final partial windows, bank
handshakes/backpressure, MSHR occupancy and FMAC completion. Run pytest afterward
to validate the output numerically.

Optional browser regression (development dependencies only):

```sh
python3 -m venv --system-site-packages sim_dashboard/.venv
sim_dashboard/.venv/bin/pip install playwright
sim_dashboard/.venv/bin/python sim_dashboard/tests/browser_check.py \
  sim_dashboard/output/rtl_4x4.html
```

It opens the file directly in installed Chrome, tests every tab, group/phase/time
controls, export, narrow layout, and asserts zero external network requests.
A full instrumented GEMM run is still required to validate completion counts
against its actual workload and elaborate every probe tap in the current full
RTL build. The current verification includes a real-testbench syntax compile
against an existing 4x4 library and the deterministic probe simulation, not that
full-run validation.

### NoC color scale and endpoint coverage

NoC views default to a fixed logarithmic color scale, expanding low activity
using `log1p(utilization / 0.0001) / log1p(10000)`. The legend and hover values
show actual percentages; the linear 0–100% option remains available. White
means measured zero and gray means unavailable. Mesh and sub-NoC averages
exclude outward-facing boundary ports for non-torus meshes, weighting each
physical link by its measured cycles. Individual links can exceed the average.

Older RTL probes wrote empty `mst_req` and `slv_req` endpoint arrays,
so these totals are unavailable in existing traces. Request directional-link
counters are collected separately and count each hop; they cannot reconstruct
unique endpoint totals. Response endpoint counters are collected. Updated probes also collect request
endpoint `valid && ready` handshakes for each remote request port (excluding
port zero), summed across groups and tiles. Rebuild the instrumented simulator
to collect these in future runs; existing compiled images retain the old probes.

The endpoint view reports `sum(mst_resp) / sum(slv_resp)` for the selected
window and recorded benchmark windows as the effective multicast/reuse factor.
It includes cached reuse and MSHR fan-out; window boundaries can skew the
window ratio. A zero denominator is undefined, and absent counters remain
unavailable.

### Benchmark diagnosis

The Benchmark diagnosis tab compares final assigned-FMAC completion intervals,
progress when only the last groups remain, mean table occupancy, peak entries,
whole-table full cycles and the fraction of occupied entry-cycles with an
unissued fetch. Its scope stays fixed to the benchmark; selecting a group
changes its detailed evidence. Completion is only established with continuous
benchmark work coverage and an exact match to the assigned FMAC total.

Rules flag groups whose unissued fraction exceeds both 50% and twice the group
median. These are investigation candidates, not asserted root causes. Current
and best tested hash spread, modeled local operand fractions, and optional
whole-run MSHRLIFE hold/flight/drain averages provide supporting comparisons.
The locality model uses the captured geometry and the same bounded address
stream as hash exploration; it does not measure runtime traffic. Lifetime
counters omit local/bypassed traffic and are explicitly separate from the
benchmark-only occupancy counters. Missing data is not treated as idle time.

Tests cover incomplete/cropped work coverage, missing lifetime counters,
whole-run lifetime parsing, and browser checks of group/phase scope.

### Request-class views and tied completions

The memory view separates single-word (`burst_len == 1`) and burst entry
occupancy. New probes collect each class every cycle, at both group and entry
level. The selected-group timeline shows total plus class occupancy; the
entry metric selector also offers each class. Older runs have no time-resolved
class split; their final MSHRLIFE-BL counters can still show completed entries
by class. These whole-run counts are labeled separately and are not used to
invent missing occupancy samples. Recompile the simulator to enable new probes.

The diagnosis now handles final completion cohorts larger than two groups.
If every group finishes in the same reporting window, it reports "Same
completion window" and "No resolved tail" rather than missing data. Missing
work coverage remains distinct. The 4x4 prefill completes in two sampled
cohorts (three groups, then thirteen), unlike the isolated G7/G8 decode tail.

### Software kernel size and sharing versus policy

The header shows `KS`, meaning rows computed by the software microkernel per
vector operation (for example `matmul_2xVL` has KS=2). This is separate from
GEMM M/N/P and the vector column count. Current campaign manifests contain
`kernel_size`; older manifests can supply `hash.kernel` as a fallback.

Future campaign app copies print `[DASHBOARD_META] {"kernel_size":2}` once on
hart zero immediately after kernel selection, before the timed region. Rebuild
the private workload ELF to get this output; existing ELFs are unchanged.
For other applications, call `dashboard_kernel_size(ks)` from
`rtl/dashboard_workload.h` outside the timed region. A captured kernel size
that conflicts with the manifest or hash model is rejected.

The sharing table shows both potential core sharing and the independent MSHR
subscriber target. Target 1 means bypass table allocation; it does not mean
that only one core uses the data. Decode KS=2 has A/B sharing 2/8 but compiled
merge targets 1/8 because the software deliberately bypasses two-sharer singles.

## Review and campaign execution

The RTL probe and optional workload-print helper are in `rtl/`.
`instrument.py` inserts the probe into a private copy of `mempool_tb.sv`;
there is no dashboard-specific datapath change to stage in `hardware/src/`.

The assertion-corrected four-arm campaign is documented in
[campaigns/gemm_assertfix_20260912/README.md](campaigns/gemm_assertfix_20260912/README.md).
The controller uses the development virtual environment (`pyelftools`, `pytest`,
and `playwright`); standalone HTML generation needs only standard-library Python.
Generated ELFs, simulator images, RTL snapshots, telemetry, logs and dashboards
are excluded from version control.

## Full telemetry without dropped intervals

The unified `generate.py` streams telemetry into compressed, lossless detail
blocks, including for multi-gigabyte traces. Transcript-only runs use the same
overview and detail interface. Every selected telemetry record is retained,
including all entry, bank and link records. The opening overview shows whole-system FPU busy-lane
utilization, MSHR occupancy, and remote response handshakes per cycle across
all captured phases. For older transcripts with only a printed overall FPU
percentage, that series is explicitly labeled and duration-weighted; it is not
converted into measured lane counters. Rates use summed numerators and
denominators; missing measurements remain unavailable and gaps are not joined.

Drag on an overview chart, click to center a detail interval, or enter start/end
cycles and choose **Inspect range**. The full-run overview stays visible while
the detailed charts load only the selected region, even across storage-block
boundaries. Detail ranges are limited to three blocks (60,000 cycles by default)
to bound browser memory. With a custom `--window`, the default block width rounds
up from 20,000 cycles to a multiple of that window. Wider selections are explicitly rejected rather than
silently truncated. Original measurement windows overlapping the selection are
retained whole; their counters are never proportionally split. The Phase selector
filters detail only. Work-progress totals carry forward from earlier records.
Benchmark roofline accounting and diagnosis retain their full-benchmark scope.

```sh
python3 sim_dashboard/generate.py \
  --transcript /absolute/path/to/transcript \
  --telemetry /absolute/path/to/telemetry.jsonl \
  --manifest /absolute/path/to/manifest.json \
  --peaks /absolute/path/to/matching-peaks.json \
  --cutoff 860000 --page-cycles 20000 \
  --out /absolute/path/to/dashboard_full.html
```

The cutoff is optional: by default, all recorded intervals are included and the
last interval end determines the captured extent. For a partial snapshot, use
`--cutoff` to retain only records ending at or before a known captured cycle.
Use stable, fully written input files; changing telemetry files or a partially
written JSON line produce an error. Copy an active run's trace before processing.

Completion is unconfirmed by default. For a finished run, use `--complete`; this
labels completion but does not perform numerical validation, and preserves the
manifest's correctness assessment. Structured telemetry fields and source-line
references are preserved. Transcript record types absent from telemetry (such as pipeline pressure) are retained too;
matching legacy counter identities are superseded by their structured probes.
Legacy counters for other groups or endpoints remain available.
A `.coverage.json` companion records input/output counts, source SHA-256,
page count, captured benchmark extent and FMAC totals. Packaging fails if any
retained record is lost or duplicated. Missing final program completion must
not be treated as successful numerical validation.

An existing full dashboard can gain the overview without reparsing its raw trace:

```sh
python3 sim_dashboard/upgrade_full.py /absolute/path/to/dashboard_full.html \
  --out /absolute/path/to/dashboard_overview.html
```

The upgrader derives overview counters from the embedded records and copies each
compressed detail block byte-for-byte. Its `.overview_audit.json` verifies those
blocks after writing. The original dashboard remains available for comparison.


## One command, optional telemetry

**Telemetry** is `telemetry.jsonl`, a structured counter file written by the RTL
instrumentation. Each line is a JSON metadata header or a sampled measurement
with a cycle interval, counter kind, and relevant group/bank/entry/link IDs.
The transcript is the simulator's human-readable log. Supply both from the same
simulation to combine software/timing prints with detailed hardware counters.
Telemetry is optional; absent probes remain unavailable, never inferred.

```sh
python3 sim_dashboard/generate.py \
  --transcript /absolute/path/to/transcript \
  --telemetry /absolute/path/to/telemetry.jsonl \
  --manifest /absolute/path/to/manifest.json \
  --peaks roofline/peaks/terapool_spatz4_fpu_8x8.json \
  --complete --out sim_dashboard/output/dashboard.html
```

Omit `--telemetry` for transcript-only input. A manifest is optional when the
required metadata is captured or supplied via `--mesh`, `--shape`, and related
options. Peak tables are optional; roofline ceilings need a matching peak table.
Repeated `--telemetry` arguments accept separate probe files from the same run;
conflicting metadata and duplicate counters are rejected. `--json-out` remains
available but explicitly materializes the full parsed dataset in memory.

`generate_full.py` is now only a compatibility wrapper around the same command;
there is no second generator implementation. Existing campaign commands keep
working. Shared HTML packaging lives in `trace_dashboard/packaging.py`.

## Burst-aware hash model

Hash analysis now requires `burst_model` and `burst_geometry` from the run's
`[DASHBOARD_META]` line or manifest. Use `tile-contained-v1` for the new RTL,
and `aligned-v1` for the preceding aligned-start VLSU with short-burst support.
Unversioned logs retain measured views but do not get an assumed hash model.
The example manifest illustrates the new profile; verify every hardware value
against the actual run before using it.

Scalar hash candidates include both A and scalar B requests. Burst candidates
include actual burst B requests, including short bursts and tile-boundary
splits. The hash page reports the modeled B request mix for the selected group.
Default sampling matches the runtime tuner's 16 evenly spaced reduction steps;
`hash.max_steps` can request a larger offline sample. Candidate ties can be
ordered differently: runtime keeps the seed, while the dashboard also displays
histogram balance. Both maximize the same sampled occupied-bank score.

`upgrade_full.py` refreshes hash analysis and diagnosis using embedded metadata
while preserving original detail blocks. See [the model and migration notes](../docs/tile_contained_burst_hash.md).

### Generation performance

The generator parses and validates each telemetry source once, preserving its
SHA-256 and checking that it has not changed during generation. Private temporary
files cache selected records in batches and store detail blocks without repeated
JSON conversion. They are created under the output directory and removed on
normal completion or an exception; allow temporary disk space for the parsed
input and detail blocks. No external pickle input is supported.

Generation temporarily pauses cyclic garbage collection while working with the
acyclic trace records; Python reference counting still releases unused records.
The previous garbage-collector state is restored afterward. All original record
intervals, counters, coverage checks, and dashboard features are retained.

Lossless gzip compression defaults to level 3 for faster generation. Use
`--compression-level 9` to favor a smaller HTML file, or level 1 to favor speed.
The decoded dashboard data is identical at every level. Level 3 produced an
approximately 33% larger HTML on a one-million-record 8×8 benchmark excerpt;
size and runtime depend on trace activity. Logs now report input validation,
partitioning, and completion of each compressed detail block with elapsed time.

Validation on the CAL2-B 8×8 FP16 trace used a fixed one-million-record excerpt:
`cProfile` runtime fell from 80.5 s to 59.4 s (26% less time). This is a sample
measurement, not a promised speedup for a full campaign. The full CAL2-B 4×4
rebuild completed with 7,297,142 records and passed the timeline browser checks;
its wall time was 551.7 s during sharply increased shared-host load, so it did
not establish a full-run wall-time improvement over the earlier build.
