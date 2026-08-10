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
Bender-managed vendored IP — patch minimally. **`spatz` is the exception: it lives at `working_dir/spatz` via a `Bender.local` path override, not in `hardware/deps/`** — edit Spatz there. `floo_noc` tracks the project branch `yr/adaptive_routing`. Only three patches exist (`hardware/deps/patches/`): `floo_noc.patch`, `register_interface.patch`, `tech_cells_generic.patch`, applied by `make update-deps`. `Bender.yml` versions are lower bounds; `Bender.lock` holds the resolved (often newer) revisions.

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

## Coding Conventions

- `.editorconfig` enforced: 2 spaces, LF, 80 cols (100 for `*.sv`/`*.svh`), tabs in Makefiles
- RTL: modules/types `snake_case`, parameters `UpperCamelCase`/`ALL_CAPS`, signals suffixed `_q`/`_d`/`_dbg`/`_next`; prefer packed arrays/structs
- C/C++ follows `.clang-format` (LLVM base)
- Commit style: imperative, scope-first — e.g., `mempool_group_mshr: fix false head-beat assertion on DRAIN_RESP transition`
- Separate RTL, software, and config changes where practical
- Call out `hardware/deps/` changes explicitly in PRs
