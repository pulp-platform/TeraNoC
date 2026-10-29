# Post-layout simulation of one group

Group (0,0) runs as the post-layout netlist of `mempool_group_floonoc_wrapper`; the other groups,
the L2 and the TB stay RTL. The activity of that one group then feeds PrimeTime power analysis.
VCS only, zero-delay: no SDF, no delay in any cell or SRAM model.

## 1. Prepare the netlist

```bash
cd hardware/postlayout
mkdir -p netlists/<tag>
python3 prep_netlist.py <fusion>/out/<lib>/mempool_group_floonoc_wrapper.v.gz netlists/<tag>/group.v
```

`prep_netlist.py` renames the top to `mempool_group_floonoc_wrapper_postlayout` (its RTL name is
taken by the 15 RTL groups), prefixes every other module with `pl_` (Fusion leaves some names
verbatim, e.g. `spatz_vsldu`), and gives every `tsn7_l1cache_*` instance
`#(.delay_reset(0), .delay_racing(0), .SRAM_DELAY(0))`. It fails if a module definition or
instance was not rewritten.

Then prove that no floating net feeds logic:

```bash
python3 check_unconnected.py netlists/<tag>/group.v --libs $(cat tsmc7_libs.txt)
```

Fusion ties every pin it leaves open to a `SYNOPSYS_UNCONNECTED_<n>` net with no driver (Z, so X
at any input that reads it); VCS reports each as `IWNF`, 234,314 times for `mshr64split_l1m`. The
check classifies every such connection bit by bit -- cell output, module output, or a submodule
input bit the submodule never reads -- and exits non-zero on anything else. Expect rc=0.

## 2. Build and run

```bash
cd hardware
make -o update-floogen compile_vcs_simvopt \
     config=terapool_spatz4_fpu_backend_4x4 buildpath=build_pl_nl \
     postlayout=1 \
     postlayout_netlist=postlayout/netlists/<tag>/group.v \
     postlayout_libs="$(tr '\n' ' ' < postlayout/tsmc7_libs.txt)" \
     generated_dir=postlayout/gen_backend_4x4 \
     snitch_trace=0 vcs_kdb= vcs_jobs=16 \
     vcs_config="-ignore initializer_driver_checks"
mkdir -p pl_run && cd pl_run
../build_pl_nl/mempool_simvopt +PRELOAD=$PWD/../pl_fp16_512x128x128.elf -l transcript
```

`tsmc7_libs.txt` lists the 12 standard-cell models (H8/H11 x SVT/LVT/ULVT, `base` and `mb`) and
the four `tsn7_l1cache` macros. Every cell the netlist instantiates is defined there exactly once;
the TSMC UDPs repeat across the files but are byte-identical.

Leave `postlayout_netlist` empty to build the **RTL stand-in**
(`mempool_group_floonoc_wrapper_postlayout_standin.sv`): the netlist's module name and flat port
list wrapped around the RTL group. It must reproduce the plain RTL run cycle for cycle, which
validates the harness independently of any netlist.

## What `postlayout=1` does

| Concern | Mechanism |
|---|---|
| Swap group (0,0) | `-DPOSTLAYOUTGR=1` → `gen_postly_group` in `terapool_cluster_floonoc_wrapper.sv` |
| TB probes reach into group internals | `-DPOSTLAYOUT` compiles out every probe include, the WFI/MAC/csr_trace blocks and the Snitch tracer. `csr_trace_any_global` survives, taken over the RTL groups (`spatz_vlsu` reads it upward). |
| Port width mismatch | 1. VCS `-msg_config=postlayout_msg.cfg`: `PCWM-W` / `TFIPC` become **errors** in `terapool_cluster_floonoc_wrapper` only. 2. A time-0 `$bits` check on every struct port, naming port + both widths (works under Questa too). |
| X from uninitialised flops/SRAMs | `+vcs+initreg+config` with `modtree mempool_group_floonoc_wrapper_postlayout 0 <postlayout_init>`: only the netlist is seeded (UDP flops and SRAM arrays alike); RTL keeps its own semantics. Override per run with `+vcs+initreg+config+<file>`. |
| X from never-written L1 | `SIM_ZERO_L1` (`postlayout_zero_l1=1`, default): the RTL groups' `tc_sram` L1 banks start at 0, as the netlist's macros do under initreg. Without it, a read of a never-written word in an RTL group ships an X data word over the mesh: the stand-in saw X on `floo_tcdm_rsp_i` from cycle 1,411. |
| X from never-written L2 | `SIM_XZERO_L2` (`postlayout_xzero_l2=1`, default). The L0 icache decodes refilled words for static branch prediction (`snitch_icache_l0.sv:294`), so an X there becomes an X prefetch address in gates. |
| Netlist boots from 0x0 | `postlayout_bootaddr_fix=1` (netlist builds): `tb/tb_postlayout_bootaddr.svh` deposits `BOOT_ADDR` on the 16 PC flops' nets during reset. See below. |
| Floating `scan_data_i` | tied to `1'b0` on the netlist instance |
| X anywhere at the boundary | `tb_postlayout_xmon` on every port of the netlist group: `[PL-X] <port>: first X/Z ...` when it happens, `clean` or a count at the end. Outputs = produced by the netlist, inputs = arriving from RTL. |
| Delays | cells: `+nospecify +notimingcheck`, `+delay_mode_zero` (all their specify delays are `(0,0)` anyway). SRAMs: `TSMC_CM_UNIT_DELAY` (functional variant, no 1 ps X pulse on every `Q` change), `delay_flush=0`, and the parameter overrides from `prep_netlist.py`. |
| Synthesis-only RTL defaults | the netlist is built under `TARGET_SYNTHESIS`; `ICACHE_L0_REFILL_REG=1` gives the RTL groups the same L0 refill register |
| Mesh / L2 map | `generated_dir=` points this build at a private copy of the three FlooNoC packages; the shared `hardware/generated/` is never touched |
| Power window | `[PWR] benchmark window opens/closes at <t> (cycle N)` from the csr_trace OR of the RTL groups |

## The RTL around the netlist must be the netlist's RTL

Port widths only catch interface drift. Before trusting a run, diff the synthesis inputs against
this tree:

* defines: `fusion/tmp/analyze.tcl` vs `build_*/compilevcs.sh` (`GROUP_MSHR_BYPASS_WAYS`,
  `_DRAIN2_FROM_Q`, `_ONE_MERGE_PER_BANK` differ but no RTL reads them);
* sources: the backend checkout's `hardware/src`, `hardware/deps` (the `floo_noc` differences are
  `floo_noc.patch`: a zero-route guard and an assertion switch) and Spatz;
* generated packages: `gen_backend_4x4/` matches the backend checkout's `hardware/generated/`
  modulo verible formatting. It differs from the base 4x4 set in the L2 address map (16 MiB,
  `0x0010_0000` per channel), which lives inside the group's AXI chimneys.

Regenerate `gen_backend_4x4/` with:

```bash
python3 hardware/scripts/gen_perimeter_map.py --num-x 4 --num-y 4 -o $OUT --l2-size 16777216 \
        --emit-yml $OUT/floo_noc_backend_4x4.yml --objective hops --link-turn-model shortest
PYTHONPATH=hardware/deps/floo_noc PATH=$(dirname $VERIBLE):$PATH python3.12 -m floogen.floo_gen \
        -c $OUT/floo_noc_backend_4x4.yml -o $OUT --only-pkg
PYTHONPATH=hardware/deps/floo_noc python3.12 hardware/scripts/gen_floo_route_tables.py \
        -c $OUT/floo_noc_backend_4x4.yml -o $OUT --turn-model shortest
```

The ELF must be built for the same config:
`CONFIG=terapool_spatz4_fpu_backend_4x4 MERGE_REQS=4 OUT_PREFIX=pl_ scripts/gen_gemm_shape_app.sh 512 128 128 16`.

## The netlist's boot address

The backend's synthesis top is `terapool_cluster_floonoc_wrapper`
(`tsmc7/fusion/design_planning/dp.tcl`, a plain `elaborate`), whose default is `BootAddr = 0`. The
group netlist therefore resets every Snitch PC to 0x0, while the bootrom is at `BOOT_ADDR`
(0xA000_0000): core 0 never boots and the whole cluster waits on it, with no X and no error. The
`mshr64split_l1m` run hung like this for 2.1 M cycles.

`BootAddr` is used only as the PC reset value (`snitch.sv`, `` `FFAR(pc_q, pc_d, BootAddr, ...)``),
so the TB loads it into the PC flops instead: a `$deposit` on their output nets at every falling
edge while the netlist is in reset. The flops receive no event until reset ends, so the value holds
until the first capture. The netlist is not modified. Fix it at the source by elaborating with
`BootAddr=32'hA000_0000`; the deposit is then a no-op, and `postlayout_bootaddr_fix=0` drops it.
The net names are Fusion's; a netlist that names them differently fails elaboration.

## Activity for PrimeTime (SAIF)

Add `postlayout_saif=1 tb_clock_period_ps=1000` to the netlist build (own `buildpath`).
`tb/tb_postlayout_saif.svh` then records every net of the netlist group, cell pins included, from
the clock edge that opens the `[PWR]` window to the one that closes it, and writes
`pl_group.saif` (or `+pl_saif=<file>`) to the run directory. `[SAIF]` lines give the window.

* The clock is set to the target period (1 GHz here) so the SAIF's DURATION and toggle rates are
  the silicon's. Nothing in the zero-delay design depends on the period; check that the cycle
  counts equal the 2 ns runs'.
* SAIF, not VCD: about 400k clock-tree cells toggle every cycle, so a VCD of the window would be
  tens of GB. VCS counts at most one transition per net per time step, so zero-delay delta
  glitches add nothing to the counts.
* The hierarchy starts at `mempool_tb`; in PrimeTime, `read_saif` with `-strip_path` set to the
  netlist instance (`mempool_tb/dut/i_mempool_cluster/gen_groups_x[0]/gen_groups_y[0]/gen_postly_group/i_group`).
  Instance names inside are the netlist's own (prep_netlist.py renames modules only).

Mergecast on/off pairs come from the software knob `mshr_mergecast` (`MERGECAST=0` for
`scripts/gen_gemm_shape_app.sh`): 0 programs the MSHR identically but leaves it disabled.

## Known risk: zero-delay races on a post-CTS netlist

With every delay at zero, the clock tree's buffers evaluate in delta cycles. A capture flop whose
clock passes through more tree cells than its launch flop's can sample the new data, which RTL
cannot do; at the RTL boundary a UDP flop and an RTL `always_ff` update in the same active region.
A wrong result, a hang, or a cycle count that drifts from the stand-in's are the symptoms. None
showed up on `mshr64split_l1m`: the fp16 512x128x128 run ends with EOC 0 and every `[SPOT]` checksum
equal to the RTL run's. VCS's `-add_seq_delay <t>` (clock-to-Q on every sequential UDP; drop
`+delay_mode_zero`, which overrides it) would cure one, but it adds delay, which this flow avoids:
decide that case by case.
