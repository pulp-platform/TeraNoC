# Verilator simulation in TeraNoC

How to build and run the Verilator flow for **fast, parallel, headless benchmarking** — no
waveforms, no traces, no assertions. Intended as the throughput complement to QuestaSim, which
stays the tool for debug and waveform work.

Verified on: `terapool_spatz4_fpu` (256 cores, 16x16), Verilator 4.228, AMD EPYC 9274F, RHEL 8.

---

## 0. Status

| Stage | State |
|---|---|
| Bender file-list generation | works |
| Verilation (RTL -> C++), full 256-core terapool | **works, 0 errors** (`--lint-only` clean too) |
| C++ compile + link | works with clang; see §2 |
| Run / cycle-count parity vs QuestaSim | **validated — 0.98% offset, explained** |

### Validation run (2026-07-31)

`sp-fmatmul-opt-burst-merge`, 512x256x512, identical ELF, identical MSHR knobs
(`NUM=64`, `WAYS_PER_BANK=4`, `HOLD_WINDOW_BURST=255`, `SERVE_TIMEOUT=255`):

| | QuestaSim (build_1) | Verilator | delta |
|---|---|---|---|
| kernel cycles | 79,086 | **78,314** | **-772 (-0.98%)** |
| wall clock | ~19 h | **41 min** | **~28x** |
| exit | `retval = 0` | `rc = 0` | |

**The 0.98% is a known, constant offset, not model error.** The only functional define that differs
is the boot address: the `verilate` target deliberately overrides `boot_addr` to `l2_base`
("*while we don't have a DPI to write a wake-up*"), so Verilator boots at `0x80000000` and skips the
bootrom that Questa runs at `0xA0000000`. Different startup -> slightly different I-cache warm-up.
The remaining three differing defines (`BYPASS_PROBE`, `ENABLE_STATS`, `RESP_HOLD_PROBE`) are
display-only.

Because the offset is constant, **Verilator-vs-Verilator comparisons are clean**; only absolute
cycle counts carry the ~1% shift versus Questa.

### Measured speed

```
Executed cycles:  3000
Wallclock time:   55.289 s
Simulation speed: 54.2603 cycles/s
```

**54.3 cyc/s vs QuestaSim's 1.85 cyc/s (~29x)** — and measured while another sim competed for CPU,
so it is conservative. Note the Questa side had WLF logging, `[LP]`/`[BP]` profiling and assertions
on, i.e. Questa-as-actually-used; a stripped Questa run would narrow the gap.

The model prints this summary itself at the end of every run — use it rather than timing externally.

---

## 1. Why it was broken, and what was fixed

Four independent problems, none of them structural. The infrastructure
(`tb/mempool_tb_verilator.sv`, `tb/verilator/*`, the `verilate` target) was complete all along.

### 1.1 Wrong assertion define — the real blocker *(fixed in `hardware/Makefile`)*

The target passed `-DCOMMON_CELLS_ASSERTS_OFF`, but this version of
`common_cells/include/common_cells/assertions.svh` gates its macros on **`INC_ASSERT`**, which is
controlled by **`ASSERTS_OFF`**. So every `` `ASSERT `` macro expanded, and two expand to SVA that
Verilator 4.x cannot parse:

* `deps/floo_noc/hw/floo_meta_buffer.sv:181,183,198` — floo_noc calls
  `` `ASSERT(name, prop, "msg") `` with three args, but the macro signature is
  `` `ASSERT(__name, __prop, __clk, __rst, __desc) ``, so the *message* lands in the **`__clk`**
  slot and yields `@(posedge "Meta data for B response must exist in Id Queue!")`.
  A latent floo_noc misuse that only surfaces when assertions are enabled.
* `deps/snitch/src/snitch.sv:3108` — uses the `##1` sequence operator.

Fix: also pass `-DASSERTS_OFF`. This suits the benchmarking use case anyway — assertions off.

### 1.2 Input-port default values *(patched in `hardware/deps/axi/`)*

Three ports declared with defaults — the project's own R-MCAST additions:

* `axi_demux.sv:75` — `mst_r_pop_mask_i = '0`
* `axi_demux_simple.sv:66` — `mst_r_pop_mask_i = '0`
* `axi_demux_simple.sv:554` — `pop_mask_i = '0`

Verilator 4.228 rejects defaults on module inputs (Verilator 5.x supports them). Guarded:

```systemverilog
`ifdef VERILATOR
  input  logic [NoMstPorts-1:0][2**AxiLookBits-1:0] mst_r_pop_mask_i,
`else
  input  logic [NoMstPorts-1:0][2**AxiLookBits-1:0] mst_r_pop_mask_i = '0,
`endif
```

Behaviour-preserving: Verilator drives unconnected inputs to 0, which is exactly what the default
declares. Costs a `PINMISSING` warning (already waived).

> **This is a `hardware/deps/` change.** It must be captured in `hardware/deps/patches/axi.patch`
> or fixed upstream, otherwise `make update-deps` silently reverts it and the flow breaks again.

### 1.3 `verilator` binary path *(no repo change; override on the command line)*

`hardware/Makefile:50` defaults to `$(INSTALL_DIR)/verilator/bin/verilator`, which does not exist
here. It is a `?=`, so override it. Note the `verilator` on `PATH` is a sepp wrapper needing a
subcommand (`verilator verilator`) — use the absolute path instead.

### 1.4 `VERILATOR_ROOT` is mis-derived *(no repo change; override on the command line)*

The binary has a compiled-in prefix of `/usr/pack/verilator-4.228-zr/linux-x64/share/verilator`,
but the kit is installed build-tree-style at `/usr/pack/verilator-4.228-zr/verilator-4.228/`. The
generated makefile therefore includes a `verilated.mk` path that does not exist. Override
`VERILATOR_ROOT` to the real root.

---

## 2. Building

Two steps, because the stock `verilate` target hardcodes `make -j4` and `g++`, both of which you
want to override for a 256-core model.

### Step 1 — verilate (RTL -> C++)

```bash
cd hardware
make -o update-floogen verilate \
  config=terapool_spatz4_fpu \
  verilator=/usr/pack/verilator-4.228-zr/verilator-4.228/bin/verilator \
  verilator_build=$PWD/vbuild_tp \
  buildpath=build_vtp app=apps/baremetal/hello_world
```

`-o update-floogen` skips floogen (needs Python >= 3.10); the committed
`generated/floo_terapool_noc_pkg.sv` is valid for every flavor. This step ends by failing at the
`verilated.mk` include (§1.4) — that is expected, and the C++ sources are already generated.

### Step 2 — compile + link (clang)

```bash
V=$PWD/vbuild_tp
make -j24 -C $V -f $V/Vmempool_tb_verilator.mk \
  VERILATOR_ROOT=/usr/pack/verilator-4.228-zr/verilator-4.228 \
  CXX=clang++ LINK=clang++ \
  OPT_FAST="-O2 -march=native -fstrict-aliasing" \
  OPT_SLOW="-O0" \
  LDFLAGS="-fuse-ld=lld -pthread -lutil -lelf"
```

Produces `vbuild_tp/Vmempool_tb_verilator`, a **standalone binary** — this is what makes parallel
benchmarking work.

#### Why clang, and why these flags

Measured on one representative generated fast-path file:

| compiler | flags | compile/file | obj |
|---|---|---|---|
| g++-9.2.0 | `-Os` (stock default) | 14.9 s | 15 KB |
| g++-9.2.0 | `-O2 -march=native` | 15.4 s | 17 KB |
| **clang++ 20.1.8** | `-Os` | **4.5 s** | 17 KB |
| **clang++ 20.1.8** | `-O1 -fstrict-aliasing -march=native` | **5.1 s** | 17 KB |
| **clang++ 20.1.8** | `-O2 -fstrict-aliasing -march=native` | **6.0 s** | 19 KB |

clang is ~3.3x faster to compile than the stock g++-9.2.0 *and* the Verilator docs report it is
~10% faster at simulation. Whole-model build drops from ~3 h to ~25-40 min.

`OPT_SLOW="-O0"` is free: 1403 of the 2896 generated files are `__Slow` (init/reset code that runs
once) and contribute nothing to simulation speed.

---

## 3. Running

```bash
cd hardware/build_vtp
../vbuild_tp/Vmempool_tb_verilator --meminit=ram,../../software/bin/apps/spatz_apps/sp-dotp
```

The app is supplied as an ELF via `--meminit=ram,<elf>`; the model boots at `L2_BASE`
(the `verilate` target overrides `boot_addr` to `l2_base`). `--term-after-cycles=N` bounds a run.

### Parallel benchmarking

The binary holds no license and needs no shared state, so fan out freely — one process per ELF:

```bash
for app in sp-dotp sp-fmatmul-opt sp-fmatmul-opt-burst-merge; do
  ( mkdir -p run_$app && cd run_$app &&
    ../vbuild_tp/Vmempool_tb_verilator --meminit=ram,../../software/bin/apps/spatz_apps/$app \
      > transcript 2>&1 ) &
done
wait
```

Each run needs its own CWD — the model writes `transcript` and any trace files there.

**Do not use `--threads`.** For N concurrent benchmarks, N single-threaded models beat N/4
four-threaded ones: threading buys latency on one simulation at the cost of synchronization
overhead, and throughput is what matters here. It is commented out in `verilator.flags`; leave it.

---

## 4. Speed knobs, in rough order of expected value

Only the compiler comparison in §2 is measured; the rest are documented-but-untested here.

| Lever | Expected | Cost / risk |
|---|---|---|
| **Compiler PGO** — clang `-fprofile-instr-generate` -> representative run -> `-fprofile-instr-use` | **5-15%** (Verilator docs) | two builds + a profiling run |
| `-O3` / `-Os` vs `-O2` | unknown; large models are **icache-bound**, so `-Os` may genuinely win | rebuild only |
| Drop `--hierarchical` | cross-module inlining; `verilator.flags` itself notes non-hierarchical "might be faster" | large compile time and RAM at 256 cores |
| `--x-assign fast --x-initial fast` | removes X-propagation work | changes X semantics; MemPool inits its memories |
| `--inline-mult` raise, or `--flatten` | more inlining | compile blowup |
| ThinLTO (`-flto=thin` + lld) | modest | compile cost |

Verilator's own `--prof-pgo` is **thread** PGO and is irrelevant to single-threaded models — do not
confuse it with compiler PGO above.

Two doc quotes worth holding together, because they point opposite ways for a model this large:
*"use the latest Clang compiler (about 10% faster than GCC)"* and *"the instruction cache size
often limits large models, and reducing code size, if possible, can be beneficial"* — with `-O2`/
`-O3` *"often provid[ing] only a minimal performance benefit"*. Measure before standardizing.

---

## 5. What you give up versus QuestaSim

The Questa-only TB instrumentation is excluded from Verilator (`mempool_tb_verilator.sv` is a
different, much thinner testbench):

* `[LP]` link profiling, `[BP]` bottleneck profiling
* `[CMS]` core-memory scoreboard (`tb_core_mem_scoreboard.sv`)
* `[GroupMerge]` MSHR merge profiling
* `noc_profiling/*.log`, `v4m_out/trace_events.csv`
* all SVA (compiled out via `ASSERTS_OFF` — including the MSHR's own invariant assertions)

So Verilator answers *"how many cycles"*, not *"why"*. Keep QuestaSim for diagnosis.

One genuine advantage beyond speed: **no DRAMSys/SystemC dependency**. Questa always links
`-sv_lib libsystemc -sv_lib libDRAMSys_Simulator` even with the default SRAM L2; the Verilator path
does not, so it runs on hosts where `make update-deps` never built DRAMSys.

---

## 6. Gotchas

* **`--meminit` rejects relative paths.** `DetectMemImageType` (`dpi_memutil.cc:103`) picks the
  image type with `find_last_of(".")`, so `../../software/bin/...` makes it read everything after
  the `..` as the file extension and die with ``Unknown image type: `/software/bin/...' ``. Use an
  **absolute path**, or append an explicit `,elf`.

* **Changing a define does NOT trigger regeneration — the most dangerous trap here.** `make
  verilate` compares timestamps, not defines: with `Vmempool_tb_verilator.mk` already present it
  prints *"is up to date"*, skips generation, and goes straight to **running the model with the old
  defines**. You get plausible benchmark numbers from the wrong configuration. Always
  `rm <build>/Vmempool_tb_verilator.mk` first, then confirm the define actually changed:
  ```bash
  grep -oE "SNITCH_TRACE=[01]" vbuild_tp/files | sort -u
  ```
  Same shape as the documented "`make compile` skips vlog" gotcha.

* **`SNITCH_TRACE=0` does not stop the trace files being created.** The `$fopen` sits in an ungated
  `always_ff @(posedge rst_i)` (`spatz_mempool_cc.sv:418`), so 256 empty `.dasm` files always
  appear. Only the *writes* are gated, and by `(i_snitch.csr_trace_q || SnitchTrace)` — `csr_trace_q`
  is set by **software**, so an app that enables the trace CSR still writes full traces even at
  `SNITCH_TRACE=0`. Check `cat *.dasm | wc -c` if a run looks unexpectedly slow.

* **Config coverage.** Only `terapool_spatz4_fpu` is known to boot on this branch; the smaller
  Spatz configs wedge at a host-chimney assertion independently of Verilator.
* **SW/HW core-count mismatch.** Build apps with the matching `config=` or you get a silent 4-core
  binary on 256-core hardware.
* **Changing flags does not force a rebuild.** `make` compares timestamps, not flags. When you
  change `OPT_FAST` or the compiler, `rm vbuild_tp/*.o` first or you link a mixed-flag model.
* **`make update-deps` reverts the AXI patch** (§1.2).
* **Cycle counts are layout-sensitive** (+/-60 cycles from code layout alone). Always A/B the same
  ELF, and check the ELF mtime predates the run you are comparing against.

---

## 7. References

* [Verilator — Simulating (Verilated-Model Runtime)](https://verilator.org/guide/latest/simulating.html)
* [Verilator — Simulation Runtime Arguments](https://verilator.org/guide/latest/exe_sim.html)
* [Embecosm — Use of OPT_FAST, OPT_SLOW and OPT](https://www.embecosm.com/appnotes/ean6/html/ch07s03s01.html)
* [Antmicro — Improving Verilator's hierarchical mode](https://antmicro.com/blog/2025/05/improving-verilator-hierarchical-mode)
