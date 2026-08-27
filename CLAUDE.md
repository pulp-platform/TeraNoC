# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**TeraNoC** is a hybrid mesh-crossbar Network-on-Chip (NoC) for scaling shared-L1-memory RISC-V manycore clusters to 1000+ cores. Branched from the [MemPool](https://github.com/pulp-platform/mempool) project, it integrates [FlooNoC](https://github.com/pulp-platform/FlooNoC) mesh routers and the [Spatz](https://github.com/pulp-platform/spatz) vector extension. Hardware is SystemVerilog; software is C compiled with RISC-V GCC/LLVM.

`AGENTS.md` is the general contributor guide (structure, style, PR conventions); this file is the Claude-facing operational guide. Both are kept in sync.

## Build Commands

### Initial Setup
```bash
git submodule update --init --recursive
make bender          # Install Bender v0.28.2 (HDL package manager)
make update-deps     # bender checkout + build DRAMSys + apply hardware/deps/patches/*
make toolchain       # Build GCC + LLVM + Spike (slow, one-time)
```
Bare `make` at the repo root runs `all: toolchain riscv-isa-sim halide` — a multi-hour toolchain build, **not** a simulation. Always name an explicit target.

### Software Build
```bash
cd software/apps/baremetal && make hello_world             # build one baremetal app
cd software/apps/spatz_apps && make sp-dotp config=mempool_spatz4_fpu  # build a Spatz kernel
make all                                                   # GCC apps only — SKIPS float (f16/f32/f8) apps
make all_llvm COMPILER=llvm                                # includes float apps
```
- **`COMPILER` default is `llvm`** for software (`software/runtime/runtime.mk`). The meaningful override is `COMPILER=gcc`. `-march` is derived from compiler **and** config — mixing `COMPILER=gcc` with a Spatz config produces wrong flags silently.
- App binaries land in `software/bin/apps/<category>/<name>`; `riscv-tests` ISA binaries land directly in `software/bin/`.
- Apps live one-per-folder with a `main.c`; an app's `data_<name>.h` is auto-generated from `software/data/gendata_params.hjson` at build time.

### Hardware Compile & Simulate (from `hardware/`)
```bash
make compile config=mempool_spatz4_fpu                     # compile RTL for QuestaSim (default goal)
app=apps/baremetal/hello_world make simc config=mempool_spatz4_fpu  # headless (vsim -c); still logs all signals to vsim.wlf
app=apps/baremetal/hello_world make sim  config=mempool_spatz4_fpu  # GUI (auto-loads scripts/questa/wave.tcl)
app=apps/baremetal/hello_world make verilate config=minpool          # Verilator
make trace                                                 # human-readable traces
```
Use `buildpath=build_X` to keep multiple build dirs (e.g. `buildpath=build_1`).

### ⚠️ Build gotchas (non-obvious, will bite a fresh instance)
- **floogen runs on every compile.** `compile`/`sim`/`simc`/`verilate`/`lint` all depend on `update-floogen`, and its make sentinel never matches the real output, so floogen re-runs unconditionally. floogen requires **Python ≥ 3.10** and is installed via `pip install .` from `hardware/deps/floo_noc/`; it also needs **`verible-verilog-format` on `PATH`** or it aborts with `RuntimeError: verible-verilog-format not found`. On hosts with older Python (or no floogen) every sim aborts.
  ✅ **The working toolchain is a conda env — use it before concluding floogen is unavailable:**
  ```bash
  export PATH=/home/dishen/.conda/envs/terapool_noc/bin:$PATH   # Python 3.12.9 + verible + floogen
  ```
  The login shell has Python 3.9.12 and no verible, so floogen fails there and the `-o update-floogen`
  workaround below is the *fallback*, not the fix. With the env on `PATH`, a mesh can actually be
  regenerated, which is what makes a 4x4 lint or a mesh switch possible at all.
  ⚠️ **A new config flavour also needs its own `config/floo_noc_<flavour>.yml`**, or update-floogen
  dies with `No rule to make target 'config/floo_noc_<flavour>.yml'`. Generate it with
  `python3 hardware/scripts/gen_perimeter_map.py --num-x X --num-y Y -o <tmpdir> --emit-yml config/floo_noc_<flavour>.yml`
  (use a throwaway `-o` so `hardware/generated/` is not disturbed).
  **Workaround — `make -o update-floogen <target>` — but ONLY when building the mesh the tree was last generated for:**
  ```bash
  cd hardware && app=... make -o update-floogen simc config=terapool_spatz4_fpu buildpath=build_X
  ```
  ⚠️ **The three files in `hardware/generated/` are MESH-SPECIFIC and SHARED by every build dir.** An earlier version of this note claimed `floo_terapool_noc_pkg.sv` is "already committed and valid for all flavors" — **both halves are false**, and it cost a wasted 4x4 build. It is **untracked** (only `perimeter_map_pkg.sv` and `floo_terapool_route_table_pkg.sv` are in git), and it **encodes the mesh**: `GroupX1Y0` is `NumY`, so 8 at 8x8 and 4 at 4x4. Skipping regeneration across a mesh change fails at elaboration with
  `perimeter_map_pkg was generated for a different mesh`.
  Switching mesh therefore means: **back up `hardware/generated/*.sv`, regenerate, build, then restore** — a bare `git checkout` is not enough because one file is untracked. Restore with a trap so a failed or killed build cannot leave the wrong mesh in place for the next build. Check first that no other build is mid-`vlog` (`pgrep -alf vlog`); sims already elaborated do not re-read these files.
- **⚠️ SCALING CHECKLIST: hardcoded address-field shifts in SOFTWARE.** The L1 word-interleave
  byte address is `word | group | tile | bank | byte`, so **every field's position depends on the
  widths below it** — widen `num_groups` and the word field moves up. Any software constant that
  encodes a field offset is only valid at the mesh it was written for.
  - 16 groups → word stride 16384 (`<<14`); **64 groups → 65536 (`<<16`)**. Tile stride is
    `4 * banks_per_tile`; group stride is `tile_stride * tiles_per_group`.
  - Derive, never hardcode: `WORD_STRIDE = 4 * BANKS_PER_TILE * NUM_TILES_PER_GROUP * NUM_GROUPS`
    (`runtime.mk` supplies all four to C). `software/runtime/arch.ld.c` and `sp-fmatmul.c`
    `gbar_base()` both do this — **keep any new site consistent with them**.
  - Also beware masks that assume a field WIDTH: `hid & 0xF0` keeps only `group[3:0]` and silently
    drops `group[5:4]` at 64 groups. Recover fields by `/` and `%` on the count, not by bit masks.
  - **This cost the whole 8x8 campaign.** `sp-fmatmul.c` hardcoded `<<14`, so at 64 groups every
    group-barrier op addressed word 60 (outside the barrier window `[240,256)`, so the RTL re-route
    never fired) and 3 of 4 went to a *remote* group. The barrier was a **silent no-op** — no hang,
    no error, just no synchronisation. Fixed 2026-08-10; see WORKLOG and
    `docs/scaleup/fpu_util_per_period.md`.
  - **One-grep liveness test, run it after ANY barrier or address change:**
    ```bash
    grep -o 'bar_rel=+[0-9]*' <run>.log | sort -u   # all +0 across a run => barrier never fired
    ```
    More generally: **a telemetry counter that is identically zero across every arm of a campaign is
    a bug report, not background.** `bar_rel`/`bar_max` were 0 in all 8x8 arms for days.

- **⚠️ The shell here is zsh, and it does NOT word-split unquoted parameters.** `for x in $list`
  iterates **once** with the whole multi-line string, where bash would iterate per line. Nothing
  errors — every downstream path/grep is simply built from the wrong value, so loops silently
  report zeros. Use `while IFS= read -r x; do ... done <<< "$list"`, which is correct in both
  shells. (Cost a monitor that reported `bench_open=0` while 17 arms were in the benchmark.)
  Related: add `grep -a` when scanning simulator logs — grep classifies some as binary and
  quietly changes behaviour.

- **⚠️ QuestaSim prefixes EVERY transcript line with `# `; VCS does not.** So an anchored pattern
  like `grep '^\[FPU\]'` or `ln.startswith(b'[FPUG]')` matches **zero** lines in a GUI run's
  transcript while working perfectly on a VCS log. It never errors — the GUI arm just silently
  contributes nothing, which reads as "that run has no data" rather than "my filter is wrong".
  This cost four separate wrong answers in one session: `groupprog.py`, `mshrctr.py`, the FPUG
  reader in `gen_fix_artifact.py`, and a barrier-firing audit that reported a healthy arm as
  **NEVER FIRED**. Normalise once at read time:
  ```bash
  sed 's/^# //' run.log | grep '^\[FPU\] bench'      # shell
  ```
  ```python
  if ln.startswith(b'# '): ln = ln[2:]                # before any startswith()/match()
  ```
  Note a prefix-tolerant regex is **not enough on its own** if a byte-level `startswith()`
  prefilter runs before it — fix the prefilter too.

- **⚠️ SystemVerilog CSV probes carry a LEADING SPACE on field 0.** The TB builds each per-group
  line with a ternary between `"%0d"` and `",%0d"`, and SV pads the shorter literal, so the output
  is `busy= 24016,17932,...`. A pattern demanding a digit straight after `=` (`([\d,]+)`) matches
  nothing and the tool reports "probe not compiled in" for a log full of them. Use `=\s*` and strip
  whitespace before `int()`. (Bit `stallg.py` and `mshrctr.py`.)

- **⚠️ `software/bin` is GLOBAL — a software rebuild can corrupt a sim that is still elaborating.**
  `hardware/Makefile:85` resolves `preload := "$(app_path)/$(app)"`, so every sim preloads the one
  shared `software/bin/apps/<cat>/<name>` path, and there is **no output-path override**. The ELF is
  read at simulation **time 0**, not at launch — so a sim that is still in elaboration/design-loading
  (QuestaSim can sit at `Time: 0 ps` for hours at 8x8) will pick up whatever ELF is on disk when it
  finally gets there. Rebuilding the app for a different config/mesh in the meantime silently hands
  that run the **wrong workload**: no crash, no error, just hours of invalid data.
  **Before any software rebuild, check for sims that have not yet reached time 0:**
  ```bash
  grep -aqm1 '\[FPU\] bench' <buildpath>/transcript && echo "ELF consumed, safe" || echo "STILL LOADING - do not rebuild"
  ```
  Back up and restore the shared ELF around the build (`exp_gbar0.sh` is the working pattern), and
  prefer preloading a **stable private copy by absolute path** (`hardware/matmul_*.elf`) for anything
  long-running, so it can never be invalidated by someone else's build.

- **DRAMSys libs are always linked.** QuestaSim is always invoked with `-sv_lib libsystemc -sv_lib libDRAMSys_Simulator`, even with the default SRAM L2. If `make update-deps` (which clones + builds DRAMSys) was skipped, vsim refuses to start with a missing `.so`.
- **⚠️ Per-hart traces refill node scratch, and only ONE of the two sources has a build knob.**
  Measured on badile15, 2026-08-27, a few hours after a full reap:

  | file | files | size | controlled by |
  |---|---:|---:|---|
  | `trace_spatz_*` | 71,424 | **343 GB** | the SOFTWARE `csr_trace` region — **no build knob** |
  | `trace_hart_*.dasm` | 23,808 | 188 GB | `snitch_trace` (Makefile:57, default **1**) |

  This filled larain10's `/scratch` to 100%, putting two running arms at risk of losing their
  results to `tar | zstd`; a one-off reap reclaimed **~6 TB** fleet-wide.

  * **Build sweep/benchmark images with `snitch_trace=0`** — verified with `make -n` to emit
    `-DSNITCH_TRACE=0`. This removes the `.dasm` share only (~a third):
    ```bash
    make compile_vcs_simvopt config=... buildpath=build_X snitch_trace=0
    ```
    Keep the default (1) for a **debug** image: `trace_hart_*.dasm` is what the "stuck PC" recipe
    and the `waveform-analysis` workflow read. The knob is per-build, so both can coexist.
  * **`spatz_trace=0` is already the default and does NOT turn the Spatz trace off.**
    `spatz_mempool_cc.sv:591` gates it on "the per-core `csr_trace_q` region **OR** a `SPATZ_TRACE`
    define", so at 0 it still emits for the whole benchmark region — which is most of a sweep arm.
    Disabling it would need an RTL force-off (a `SPATZ_TRACE = -1` sentinel or a second define);
    switching `csr_trace` off instead is NOT an option, because the `[FPU]`/`[BP]` TB counters the
    dashboards read are gated on the same signal.
  * Until then `scripts/badist/loops/trace_reap_loop.sh` truncates both hourly above 40 GB/node.
    Truncation is safe on a live sim (the handle stays valid, blocks free immediately).
- **Terabool elaboration is slow** (`voptk2` ~7+ min before `run` starts); this is normal, not a hang.

### Testing
```bash
make riscv-tests                              # full ISA flow (root): build suite + Spike + Verilator RTL sim
cd software && make riscv-tests COMPILER=gcc  # build MemPool ISA test binaries only
```
**Root `riscv-tests` uses `CONFIG` (uppercase, default `test_4x4noc_64core`), not `config`.** Passing `config=...` to the root flow is silently ignored.

### Formatting & Linting
```bash
make format               # clang-format on C/C++ + autopep8 on software/data/*.py
cd hardware && make lint   # Spyglass RTL linting (also runs update-floogen)
```
⚠️ **`make lint` does not work as written — it reports success while checking nothing.** Three
separate defects, all of which must be worked around:
1. **The source list includes the testbench.** It is built with `bender script verilator -t rtl
   -t mempool_verilator`, which drags in `hardware/tb/mempool_tb_verilator.sv` and
   `common_verification/src/clk_rst_gen.sv`. Spyglass hits their non-synthesizable constructs and
   prints `***Syntax Errors detected - RULE CHECKING ABORTED***` — **zero rules ever run**. Filter
   them out of `spyglass/tmp/files` before invoking sg_shell.
2. **A pattern-rule bug drops the file list entirely.** `hardware/Makefile` declares
   `.PHONY: $(SPYGLASS_WORK_DIR)/tmp/files` but writes the recipe as `$(SPYGLASS_WORK_DIR)/tmp/files%:`
   — a *pattern* whose `%` must match ≥1 character, so the plain name has no recipe. make says
   "Nothing to be done", the list is never written, sg_shell fails with
   ``` `sourcelist' file `tmp/files' does not exist ``` — **and make still exits 0.** Build
   `spyglass/tmp/files1` (which the pattern does match) and `mv` it into place.
3. **`update-floogen` needs the conda env** (see the floogen note above), and rewrites the shared
   `hardware/generated/`. Snapshot all three files and restore from a trap; assert the regenerated
   `NumMeshX` matches the config before linting, or a floogen failure silently lints the wrong mesh.

Reports land in `hardware/spyglass/sg_projects/terapool_<timestamp>/consolidated_reports/*/` —
`moresimple.rpt` for the one-line-per-violation list, `spyglass.log` for the message text with
file:line. **Each run creates a new timestamped directory**, and a stale `sg_projects/terapool/`
also exists, so sort by mtime or you will read an old report.

## Configuration System

Configs live in `config/`. Set via `config=<flavor>`. `config/config.mk` is the master (defaults to `mempool`); it includes the flavor `.mk`.

| Flavor | cores | groups | cores/tile | num_x | Spatz | notes |
|---|---|---|---|---|---|---|
| `minpool` | 16 | 4 | — | — | no | `channel_config_mode=narrow` |
| `mempool` | 256 | 4 | 4 | 2 | no | default |
| `mempool_spatz4_fpu` | 64 | 4 | 1 | 2 | yes | `noc_router_remapping=3` |
| `terapool_spatz4_fpu` | 256 | 16 | 1 | 4 | yes | `noc_port_hash=7`, `group_mshr_num=64` |
| `minpool_spatz4_fpu` | 4 | 4 | 1 | — | yes | smallest Spatz debug target |
| `systolic` | 256 | 4 | 4 | — | no | activates XQueue extensions |

Cores/tile = 1 (Spatz flavors) means one Snitch+Spatz core complex per tile; the plain MemPool flavors pack 4 scalar cores per tile.

**Key variables** (in the flavor `.mk`): `num_cores`, `num_groups`, `num_cores_per_tile`, `num_x`, `vlen`, `spatz`, `noc_topology` (0=2D-mesh, 1=torus), `noc_routing_algorithm` (0=XY, 1=odd-even, 2=o1), `noc_virtual_channel_num`.

**Channel modes** (`channel_config_mode`, in every flavor): `baseline` / `narrow` / `enhanced` — controls `noc_req_*_channel_num` / `noc_resp_channel_num` multi-channel bandwidth split.

**Performance / active-dev knobs** (Spatz flavors):
- `noc_router_remapping`: `0`=off, `1`=req, `2`=resp, `3`=req+resp. (`mempool_spatz4_fpu` ships `3`; `terapool_spatz4_fpu` ships `0`.)
- `noc_port_hash` (bitmask): bit0=req-port hash, bit1=resp temporal round-robin, bit2=resp spatial round-robin. `7`=all on.
- `noc_router_remap_group_size`, `tile_id_remap`, `noc_router_{input,output}_fifo_dep` (raise fifo depth first when router backpressure stalls appear).
- **`group_mshr_*`** (the actively-developed `mempool_group_mshr.sv` burst-merger): `group_mshr_num` (peak outstanding bursts — too small → sim deadlock), `group_mshr_merge_reqs`, `group_mshr_enable_single`, `group_mshr_enable_stats`, `group_mshr_stats_period`, `group_merge_profiling`.

## Architecture

### Hardware Hierarchy (`hardware/src/`)
Instantiation chain (verify with grep before relying on it):
```
mempool_system
└─ mempool_cluster_floonoc_wrapper / terapool_cluster_floonoc_wrapper
   └─ mempool_group_floonoc_wrapper        ← remote-traffic hub (see below)
      └─ mempool_group
         ├─ mempool_tile  ×N               → mempool_cc (or spatz_mempool_cc from deps) = leaf core complex
         └─ mempool_group_mshr             ← inside mempool_group (if EnableGroupMshr), NOT a sibling of the group
```
- **`mempool_group_floonoc_wrapper.sv`** is the single most important file for remote-memory traffic: MemPool→FlooNoC req remapping, the per-tile crossbar that steers arriving floo requests, FlooNoC→MemPool resp remapping, and the `floo_router` instances (narrow-req / wide-req / resp channels).
- **`mempool_group_mshr.sv`** — coalesces outstanding remote loads, single/burst merging, response cache; active development area. (A stale `mempool_group_mshr.sv.bak` sits next to it — ignore/delete it.)
- **`mempool_pkg.sv`** — central package: all inter-module types (`floo_tcdm_*`, meta structs) and sizing params (`NumGroups`, `NumTilesPerGroup`, `BurstLenWidth`, …). Read this first when tracing any RTL type.
- **`routing_table_pkg.sv`** — static precomputed FlooNoC routing tables consumed by the routers.
- `floo_remapper.sv` — distributes traffic across multiple NoC channels.
- The NoC is hybrid: **intra-group** combinational logarithmic crossbars; **inter-group** 32-bit fine-grained 2D-mesh (or torus, `noc_topology=1`) FlooNoC routers.
- `axi_rab_wrap.sv` and `selector.sv` are currently orphaned (no instantiation site) — leftovers, not in the active data path.

**Byte-address layout & MSHR indexing** (MemPool word-interleave; terapool_spatz4_fpu widths — `ByteOffset=2`, banks/tile=2b, tiles/group=4b, groups=4b):
```
bit:   31 ........ 12 | 11 10 9 8 | 7 6 5 4 | 3 2 | 1 0
field: bank_row(in-bank)|  GROUP   |  TILE   | bank | byte
```
Consecutive words round-robin bank→tile→group (full 1024-word/4KB sweep, then `bank_row++`). **Target NoC group** = `addr[ByteOffset+log2(BanksPerTile)+log2(TilesPerGroup) +: log2(NumGroups)]` = byte-addr **[11:8]** (carried as `tgt_group_id`; decode at `mempool_tile.sv:1192`). **A request enters the MSHR of its SOURCE core's group** (hartid=`(group<<4)|tile`), *not* the address — the group MSHR is source-side (`mempool_group.sv:451-458`), coalescing its own 16 cores' outgoing remote reqs (so coalescing is only among same-group cores → matmul B-share is degree-2). **The BANK within that MSHR is address-hashed**: `req_bank = mshr_bank_of(req_addr_key, tgt_group_id)` (`mempool_group_mshr.sv:1075`, knob `group_mshr_bank_hash` 0=legacy strided-XOR-fold / 1=xorshift); the *way* (1 of 4) is arbitration. Full decode + hash analysis: `docs/mshr_bank_hash_design.md` §0.

### Hardware Dependencies (`hardware/deps/`)
Bender-managed vendored IP — patch minimally. **`spatz` is the exception: it lives at `working_dir/spatz` via a `Bender.local` path override, not in `hardware/deps/`** — edit Spatz there. `floo_noc` tracks the project branch `yr/adaptive_routing`. **Four** patches exist (`hardware/deps/patches/`): `axi.patch`, `floo_noc.patch`, `register_interface.patch`, `tech_cells_generic.patch`, applied by `make update-deps`. (This said "three" and omitted `axi.patch` — a modified `axi` checkout is expected, not stray.)

⚠️ **`hardware/deps/spatz` is a stale, UNUSED checkout and it carries local modifications with no patch file.** `Bender.local` overrides spatz to `working_dir/spatz`, and a build pulls 32 files from there and **0** from `hardware/deps/spatz`. Do not edit it and do not trust it when reading Spatz RTL — verify which path `compilevcs.sh` actually lists first.

⚠️ **`Bender.lock` in the working tree is NOT the committed one.** `bender clone` converted 12 dependencies from pinned git revisions to `Path: hardware/deps/<dep>` with `revision: null`, so the local lock pins **nothing**. Keep it unstaged; when a genuine pin must change (e.g. the spatz revision), stage that hunk alone with `git add -p`. `Bender.yml` versions are lower bounds; `Bender.lock` holds the resolved (often newer) revisions.

### FlooNoC Generation
```bash
make update-floonoc                                        # from root (FLOO_CFG default = terapool)
cd hardware && make update-floogen config=mempool_spatz4_fpu
```
All configs share `name: terapool`, so the only generated file is `hardware/generated/floo_terapool_noc_pkg.sv` (the config flavor changes the topology/routing *inside* it).

### Software Structure
- `software/apps/{baremetal,spatz_apps,omp,halide,systolic}/` — each app in its own folder with `main.c`.
- `software/kernels/{baremetal,omp,systolic}/` — header-only kernel libraries (on the include path); edit kernel logic here, not in `main.c`.
- `software/tests/` — separate regression tree (`baremetal/`, `omp/`); built via `make -C software tests`.
- `software/runtime/` — bootrom, linker script (`link.ld`), encoding headers.
- `software/riscv-tests/isa/` — RISC-V ISA unit tests.

### Simulation & Debug Tooling (QuestaSim only — all excluded from Verilator)
TB profiling is gated by `csr_trace_any_global` (a CSR the benchmark software sets at its start/end) — counters read **zero until the benchmark enables tracing**. Output tags to grep in the transcript:
- `[LP]` — `tb_noc_link_profiling.svh`, link utilization (always on).
- `[BP]` — `tb_noc_bottleneck_profiling.svh`, per-stage handshake/stall/idle classification (always on).
- `[CMS]` / `[CMS WARN]` / `[CMS FINAL]` — `tb_core_mem_scoreboard.sv` (instance `u_cms`): a VIP scoreboard tracking every inflight core memory request (Snitch + Spatz), warning on stuck (>1000-cyc) requests, orphan responses, and duplicate-id allocations. Compile out with `+define+CMS_DISABLE`; waveform state under `/mempool_tb/u_cms/`.
- `[GroupMerge]` — `tb_group_merge.svh`, MSHR merge efficiency (enable with `group_merge_profiling=1`).
- `noc_profiling/*.log` files — `tb_noc_profiling.svh` (enable with `noc_profiling=1`); `v4m_out/trace_events.csv` — per-link mesh trace (large).

QuestaSim debug TCL lives in `hardware/scripts/questa/` (`wave.tcl` + specialized `wave_*.tcl`, plus MSHR/hang debug scripts). Verilator waveform dump is off by default — uncomment the `--trace` line in `hardware/Makefile` (~line 468). For cycle-level waveform analysis use the `waveform-analysis` skill (WAL over WLF→VCD→FST). Tools referenced: QuestaSim 2023.4-zr (primary), VCS 2024.09-zr, Verilator, Spike.

## Distributed Simulation (badile fleet)

`fenga1` runs at load ~105 on 96 threads with a sweep on it. The badile fleet is ~25
idle 12-core Ryzen 9900X desktops. **`docs/badist_fleet.md` is the full guide** — this
is the short form.

Two pieces, deliberately separate: **`~/badist`** is the generic service (hosts, jobs,
resources, results — knows nothing about simulators; written by msc26f31, reference in
`~/badist/README.md` + `~/badist/AGENTS.md`), and **`scripts/badist/teranoc_fleet.py`**
is our client (what an arm is, how VCS/Verilator are invoked, where results land).

```sh
badist nodes                                                   # fleet health FIRST
scripts/badist/teranoc_fleet.py submit --arms arms.txt --run-prefix run6 --dry-run
scripts/badist/teranoc_fleet.py submit --arms arms.txt --run-prefix run6
scripts/badist/teranoc_fleet.py status ; scripts/badist/teranoc_fleet.py fetch
scripts/badist/teranoc_fleet.py license                        # VCS seat headroom
```

`arms.txt` is `<name> <elf> [image]` per line (paths relative to `hardware/`); or drive
it from `scripts/gemm_sweep_shapes.txt` with `--shapes ... --elf-template ...`.

- **Results land in `hardware/<run-prefix>_<arm>/transcript`**, the same layout
  `launch_bp_sweep.sh` produces locally, so `gen_fp16_sweep_dash.py` and every other
  scraper works unchanged. That routing is carried by the job's opaque `meta` blob.
- **⚠️ The VCS licence, not the fleet, is the cap.** Our simv holds
  **`VCS-Base-Runtime-Pkg`** — *not* the `VCSRuntime_Net` in badist's README, which does
  not exist on our server. 100 seats department-wide, one per arm held for the arm's
  whole life; 90 were in use when this was written. The client ships a governor
  (`--max-parallel 24 --reserve-licenses 20`); jobs held `pending` by it are correct
  behaviour, not a hang. **Distributing does not create seats** — it buys a full 4.4 GHz
  core per arm instead of nine tenths of a contended one.
- **Fall back, do not wait.** `--fallback questa` runs VCS and, if VCS exits before
  simulation time 0 (the only trace a refused seat leaves), re-runs the same ELF under
  QuestaSim *in the same job*. Questa's pool is `msimhdlsim` — **400 seats**, ~105 in use
  — and VCS/Questa cycle counts are validated identical, so the results pool. The price:
  Questa needs **15.9 GB** against VCS's 2.0 GB, and a job that might fall back must be
  *placed* for that, so a 62 GB node drops from ~10 slots to 3. Setting `--fallback` also
  drops `+vcs+lic+wait` (a queued simv never fails, so the fallback would never fire).
  The Questa image is a compiled **build directory** (`build_bp_q`), shared read-only by
  every arm via symlinks; build it with
  `make -o update-floogen compile config=terapool_spatz4_fpu buildpath=build_bp_q group_mshr_merge_reqs=16`
  and diff its `+define+` set against the VCS image first.
- **`--backend verilator` takes no licence at all**, so it can use the whole fleet — but
  it is **4x4 only** (it fails at 8x8), and its cycle counts have never been validated
  against VCS here. Image `vbuild_4x4/Vmempool_tb_verilator`, a single 456 MB binary.
- **`/usr/scratch/fenga1/...` and `/home` are automounted on every node; `/scratch` and
  `/tmp` are node-local.** The client refuses any image or ELF that is not fleet-visible,
  and refuses an ELF under `software/bin` (rebuilt in place, read at simulation *time 0*
  — a rebuild mid-launch silently hands jobs a different workload).
- **`cload badile` does not work** (the system `cload` only knows tortin, mont-fort,
  attelas, pisoc, design, sassauna, vilan, dolent, gpu). Use `badist nodes`, or
  `rup badile01 …`. `suninfo badile` lists every machine with its specs — `badile01-49`
  are the 64 GB Ryzens, `badile101-111` are 2–4 core 16 GB and out of scope.
- **`scripts/badist/workload.sh`** answers "what is running and what is blocking it":
  seat pools, fenga1 load and local sims, per-arm sweep phase, fleet batches and node
  health. Its `arms` view cross-references the ledger, so a fleet arm reads `on-fleet`
  rather than being mistaken for a dead local run — and a genuinely dead arm (4 KB
  transcript, no process, untouched 15 min) is called **DEAD**, not "loading".
- **⚠️ A refused VCS seat kills the simv in seconds and says so only on stderr.** On
  2026-08-21 that silently killed **38 of 61** arms of a local sweep whose launcher sent
  stderr to `/dev/null`; each left a 4 KB banner-only transcript and read as "still
  loading" for hours. Never discard stderr from a simulator launch.
- The controller is optional: killing `submit` stops new dispatch only. Running arms keep
  going, keep reporting and still deliver — check `badist status`, do not resubmit.
- **Validated 2026-08-21:** `16_512x128x128` on badile34 returned **7,876 cycles**, exactly
  the local figure, in 2,362 s against 67 min on a load-106 fenga1 — 1.7× faster, RSS
  2.03 GB.

## Coding Conventions

- `.editorconfig` enforced: 2 spaces, LF, 80 cols (100 for `*.sv`/`*.svh`), tabs in Makefiles
- RTL: modules/types `snake_case`, parameters `UpperCamelCase`/`ALL_CAPS`, signals suffixed `_q`/`_d`/`_dbg`/`_next`; prefer packed arrays/structs
- C/C++ follows `.clang-format` (LLVM base)
- Commit style: imperative, scope-first — e.g., `mempool_group_mshr: fix false head-beat assertion on DRAIN_RESP transition`
- Separate RTL, software, and config changes where practical
- Call out `hardware/deps/` changes explicitly in PRs

## Shared Knowledge Base (Basic Memory)

Durable engineering knowledge for the TeraNoC+Spatz+backend work — decisions
(with rationale and supersession chains), contracts, experiment results, and
open tasks — lives in the Basic Memory project **`teranoc-spatz-plus`** at
`/home/zexifu/knowledge/teranoc_spatz_plus/` (populated 2026-08-23 from this
repo's docs, WORKLOG, and session history; migration plan:
`~/knowledge/teranoc-migration-plan.md`).

- **Read** at session start: use the basic-memory plugin (`search_notes`, the
  session briefing, `memory://` links) to pick up current state and open tasks
  before substantial work. Query by type — e.g. tasks with `status: active`,
  decisions with `status: open`.
- **Write** new durable knowledge THERE, not into new per-repo log files:
  decisions (rationale + alternatives), measured results with dates, resolved
  root causes, and changes to contracts (CSR map, knob defaults, probe
  definitions). Repo-local `docs/*.md` and WORKLOG.md stay the authoritative
  project artifacts; the KB is the distilled index above them.
- This file keeps build/usage gotchas. Some facts here can drift faster than
  the KB — e.g. `group_mshr_bank_hash` modes (now ships 3, field-select),
  `noc_router_remapping` (terapool now ships 2), hold-window values (burst
  2047 / single 0). When in doubt, trust `contracts/` notes in the KB.
