# GVSoC calibration against the current RTL — handover (2026-09-28)

For an agent calibrating the GVSoC TeraNoC+Spatz model against this repo's RTL. It covers:
1. which commits changed behaviour and what each one means for a model;
2. the hardware and software configuration the reference numbers were measured on;
3. the reference numbers themselves, with where the raw data lives;
4. how to read the probes, and the traps in them.

Repo: `/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC`, branch `zexin/teranoc_spatz_mshr`,
HEAD `dd6056fa` (+ uncommitted testbench-only probes, see §6). `WORKLOG.md` has the full reasoning
behind every item below (search the dates); this doc is the index.

---

## 1. Quick start

```sh
cd /usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware/elf_split
./calib_snapshot.sh                       # refresh calib_logs/ from the fleet (running jobs)
column -t -s$'\t' calib_logs/index.tsv    # every run: ELF, image, progress, verdict, cycles
zstd -dc calib_logs/<arm>.log.zst | less  # the probe lines of one run (Questa "# " prefix removed)
python3 ../../scripts/qwen_perf_analyze.py --from 40000 --to 60000 <(zstd -dc calib_logs/<arm>.log.zst)
```

* `calib_logs/index.tsv` columns: arm, badist batch, job, node, **ELF path**, **image path**, probe
  line count, last benchmark cycle seen, verdict (`success!`/`FAIL`/`-`), `took` = the timed-region
  cycle count printed by the app ("The execution took N cycles").
* Finished jobs are also archived whole (transcript + trace files) by badist:
  `/usr/scratch/fenga1/zexifu/badist-results/<batch>/<job>.tar.zst`.
* Running jobs keep their transcript only on the node, `/scratch*/zexifu_cache/badist/run/<batch>/<job>/transcript`
  (node-local, reaped, and a node can lose it -- badile49 did on 2026-09-28). `calib_snapshot.sh`
  keeps the last good snapshot if a node or run dir is gone.
* Live progress: `./fleet_peek.sh submit_<batch>.log arms_<file>.txt [window_cycles]`.

---

## 2. Commits that change behaviour (newest first)

| commit | what changed | what a model needs |
|---|---|---|
| `dd6056fa` | qwen-gate-up: K split for every small batch | SW only (§4). QWEN_KSPLIT cores share one output patch, each on KT/ks rows of every K tile; partials summed once per projection under an MSHR bypass. |
| `be850df1` | qwen-gate-up: K split (pairs, 8x8 B=16) + `GEMM_KSPLIT` in `software/runtime/gemm_config.h` / `mshr_cfg.h` | SW; also changes the MSHR merge targets derived for those shapes. |
| `a8debb11` | **AXI (DMA/L2) mesh: y-first routing + link-load-aware L2 channel placement, default at 8x8**; `group_mshr_merge_reqs` default 4 | 8x8 route tables are strict YX; L2 channels reassigned to the same 32 perimeter gates (20 of 32 moved), `PeriphHbmChannel` 13 -> 0. Worst AXI link 4 -> 2 DMA streams. 4x4 unchanged (shortest/hops). merge_reqs 4 = the split MSHR's real bound (a slice serves 4 tiles); measured cycle-identical to 16. |
| `e112344e` | **Posted DMA writes into L1** (`dma_posted_writes=1` default) | The L1 bank accepts a wide DMA write regardless of its response queue; the tcdm_wide_narrow_mux generates the ack. Adds the `[DMAP]`/`[L2BW]` probe. |
| `5e887367` | qwen-gate-up: taller K tiles (auto KT <= 640), continuous W stream, sweep-aligned L2 K-tile slots | SW (§4). |
| `c6c285e4` | qwen-gate-up: 4x4 decode group patch (`GEMM_DECODE_RC_PER_GROUP=4`), one-stripe W row pad | SW. |
| `1feca488` | qwen-gate-up: P strips for large batch | SW. |
| `eeddded8` | Bender.lock: spatz `b040b94` | Spatz RTL used by every image. |
| `65b5e711` | split MSHR slice: register responses per NoC lane | +1 cycle on the slice response path. |
| `f8038b94` | L2: NoC windows sized for configured capacity | L2 is 512 MiB (`l2_size=536870912`) in every run here. |
| `2ce856bc`, `b414c874` | resp remapping isolated per port; `floo_remapper` rotates on valid traffic (not every cycle) | §3 remapper description. |
| `1d34626c` (+`c6abf531`, `179f461b`) | **Group MSHR split into 8 slices** (`group_mshr_split=1`) | Rows R0..R3 serve tiles 4m..4m+3 and take bursts; columns C0..C3 serve tiles m, m+4, m+8, m+12 and take singles (decode). 8 entries + 1 overflow per slice. Docs: `docs/mshr_split_design.md`. |

Older context (MSHR merge/multicast, VLSU bursts, ParityDrain, ROB rework) is in WORKLOG and the
memory notes; everything measured here runs on top of it.

---

## 3. Hardware configuration of the reference images

All images are VCS builds (`make compile_vcs_simvopt ... snitch_trace=0`), config
`terapool_spatz4_fpu` (4x4) or `terapool_spatz4_fpu_8x8`, `l2_size=536870912`, via
`hardware/elf_split/build_image.sh` (backs up and restores the shared `hardware/generated/`).
Defines verified from each build log.

| | 4x4 | 8x8 |
|---|---|---|
| groups / cores (1 Snitch+Spatz per tile, 16 tiles/group) | 16 / 256 | 64 / 1024 |
| Spatz | 4 FPU lanes, fp16 packed 2/lane -> **8 fp16 FMA/cycle/core**; VLEN 512 | same |
| VLSU | ROB 32 ids per lane (`spatz_vlsu_rob_depth=32`), dual load (`=2`, two loads in flight), block alloc on | same |
| TCDM NoC | 32-bit word-level meshes, one router per tile per port: 2 wide req ports + 2 resp ports per tile (`channel_config_mode=baseline`), 1 VC, router FIFO in/out 2/2 | same |
| req / resp remapping | `noc_router_remapping=3`, group size 4, interleaved; `noc_port_hash=7` | same |
| group MSHR | split, 8 slices x (8 + 1 overflow) entries, merge_reqs 4 | same |
| L2 | 16 channels, 1 KiB interleave on the L1 group bits | 32 channels (channel c serves groups 2c, 2c+1) |
| AXI wide mesh (DMA) | 512-bit, shortest routing, hop-optimal placement | 512-bit, **strict YX + link-load placement** |
| DMA | frontend -> split midend -> distributed midend (forks every 1 KiB piece to all groups in LOCKSTEP) -> per-group backend (AxReqFifoDepth 8); posted L1 writes | same |

Images (`hardware/<dir>/mempool_simvopt`):

| image | mesh | what it is |
|---|---|---|
| `build_split_vcs_mr4` | 4x4 | **current default 4x4** (= HEAD RTL) |
| `build_split_vcs_8x8_yx` | 8x8 | **current default 8x8** (= HEAD RTL) |
| `build_split_vcs_lnp` | 4x4 | HEAD RTL + the new testbench probes (§6: issue-based FPU util, `[LDP]`, `[SUBNOC]`) |
| `build_split_vcs_rob64` | 4x4 | experiment: `spatz_vlsu_rob_depth=64` |
| `build_split_vcs_8x8_p3` / `_p2` | 8x8 | previous default: shortest routing, hop-optimal placement (posted writes on) |
| `build_split_vcs_pw1` / `_pw0` | 4x4 | posted writes on/off A/B, merge_reqs 16 |

---

## 4. Software: qwen-gate-up (the calibration workload)

`G = X·Wgate, U = X·Wup`, X:[B][K], W:[K][P], fp16, streamed from L2 in K tiles of KT rows,
double-buffered in L1 (one DMA per tile, continuous across projections). App:
`software/apps/spatz_apps/qwen-gate-up/` (README is the spec). Build:

```sh
cd software/apps/spatz_apps
make qwen-gate-up config=terapool_spatz4_fpu[_8x8] icache_warmup=1 qwen_b=<B> qwen_k=5120 qwen_p=16384 l2_size=536870912
# small self-checking shapes add: qwen_k=128 qwen_kt=32 qwen_check=1|2 qwen_preload=1
```

Every ELF used is kept with its build log next to it (`hardware/elf_split/{kt,ks,ks2,sb,x8}/<tag>.{elf,log}`);
the build log carries every `-D` define. Derived parameters, full size K=5120 P=16384 (HEAD):

| mesh, B | KS / LMUL | K split | KT / strips | per-core span, W load | W / X sharers per group |
|---|---|---|---|---|---|
| 4x4 B=1 | 1 / m8 | 4 | 160 / 1 | 256 col, 512 B | 1 / 4 |
| 4x4 B=2 | 2 / m8 | 4 | 160 / 1 | 256, 512 B | 1 / 4 |
| 4x4 B=4 | 4 / m4 | 2 | 160 / 1 | 128, 256 B | 1 / 8 |
| 4x4 B=8 | 8 / m2 | 1 | 160 / 1 | 64, 128 B | 1 / 16 |
| 4x4 B=16 | 8 / m2 | 1 | 320 / 2 | 64, 128 B | 2 / 8 |
| 4x4 B=32/64 | 8 / m2 | 1 | 640 / 4 | 64 / 128 | 4 / 4 |
| 8x8 B=1 / 2 | 1 m8 / 2 m8 | 16 | 640 / 1 | 256, 512 B | 1 / 1 |
| 8x8 B=4 | 4 / m4 | 8 | 640 / 1 | 128, 256 B | 1 / 2 |
| 8x8 B=8 | 8 / m2 | 4 | 640 / 1 | 64, 128 B | 1 / 4 |
| 8x8 B=16 | 8 / m2 | 2 | 640 / 1 | 64, 128 B | 2 / 4 |
| 8x8 B>=32 | 8 / m2 | 1 | 640 / 1 | 64..256 | 4 / 4 |

ELFs named `sb/s8_b*` were built BEFORE the 8x8 small-batch K split, with `qwen_span_align=4`
(the default layout would not fit L2 there); `sb/s4_*` and `kt/*` are the no-split baselines.

---

## 5. Reference numbers

### 5.1 End-to-end cycles, small self-checking shapes (exact targets)

`took` = timed-region cycles; all `success!` unless noted. Images: 4x4 `mr4`, 8x8 `8x8_yx`.

| arm | shape (B x K x P, KT/PT) | took |
|---|---|---|
| mr4_kc1_stream_4strip | 32 x 128 x 16384, KT 32, PT 4096 | 103,055 |
| mr4_kc2_stream_2strip_fill | 64 x 128 x 8192, KT 32, PT 4096 | 102,738 |
| mr4_kc3_legacy_odd_2strip | 32 x 96 x 8192, KT 32, PT 4096 | 41,293 |
| mr4_kc4_auto_small | 32 x 256 x 8192, auto | 74,122 |
| ks2_c4_b1_p1 / _p2 | 4x4, 1 x 128 x 16384, KT 32, ksplit 4 | 23,851 / 23,844 (p2 verify pending) |
| ks2_c4_b2_p1 / _p2 | 4x4, B=2, ksplit 4 | 24,277 / 24,131 |
| ks2_c4_b4_p1 / _p2 | 4x4, B=4, ksplit 2 | 24,205 / 24,510 |
| ks2_c8_b1_p1 / _p2 | 8x8, B=1, ksplit 16 | 19,672 / 19,875 (verify pending) |
| ks2_c8_b2 / b4 / b8 / b16 (p1, p2) | 8x8, ksplit 16 / 8 / 4 / 2 | 20,684 20,894 / 21,883 21,295 / 20,714 20,701 / 23,595 23,906 |
| x8yx_c_b64 | 8x8, 64 x 64 x 8192, KT 32 | 14,232 |

(`_p1` = unit pattern, `_p2` = ones pattern: same work, different data -- the spread between
them is the model's noise floor for data-dependent effects.) With posted DMA writes OFF (`pw0_*`,
merge_reqs 16) the same ELFs take kc1 102,978 and kc4 74,618 -- the posted-write effect to model.

### 5.2 Full-size steady state (K=5120, P=16384)

These runs do not finish within a day, so the unit is **cycles per K tile** in steady state
(time between successive DMA refill launches, from `[DMAP]`), plus the L2 read rate.

| mesh | B | split | cycles / K tile | ideal compute / tile | DMA-only / tile | true efficiency |
|---|---|---|---|---|---|---|
| 4x4 | 1 | none / 4 | 10k / 10k | 1,280 | ~5.1k | 12.8% |
| 4x4 | 2 | none / 4 | 10k / 9k | 2,560 | ~5.1k | 26-28% |
| 4x4 | 4 | none / 2 | 9k / 9k | 5,120 | ~5.1k | 57% |
| 4x4 | 8 | none | 11k | 10,240 | ~5.1k | 93% |
| 4x4 | 16 | none | ~21.5k (KT 320, PT 8192) | 20,480 | - | 95% |
| 8x8 | 1 | none(span4) / 16 | 22-23k / 17-18k | 1,280 | 10.9k | 5.7% / 7.3% |
| 8x8 | 2 | none(span4) / 16 | 25-27k / 17k | 2,560 | 10.9k | 9.8% / 15% |
| 8x8 | 4 | none(span4) / 8 | 34-37k / 20-22k | 5,120 | 10.9k | 14% / 24% |
| 8x8 | 8 | none(span4) | 45k | 10,240 | 10.9k | 23% |
| 8x8 | 16 | none / 2 | 41k / 25-26k | 20,480 | 10.9k | 50% / 80% |
| 8x8 | 32 / 64 | none | in-tile util 96.6% / 98.2% | - | - | - |

`ideal compute` = B*KT*P / (cores*8). "true efficiency" = ideal / actual per tile. Sources
(`calib_logs/`): 4x4 `sb_4_*`, `ks2_p4_*`, `ks_b4*`, `pw1_dp_b16_default`; 8x8 `sb_8_*`,
`ks2_p8_*`, `x8yx_b*`, `ks_b16`.

### 5.3 DMA / L2 / AXI mesh

* 8x8 L2 read rate during a DMA fill: **30.1 beats/cycle of 32** (64 B beats, 1926 B/cycle) on the
  yx image; **11.8** on the old routing (`x8p3_*`), where the corner channel waited on the mesh 63%
  of cycles. Per group 0.47 vs 0.18 beats/cycle (the lockstep midend holds all groups to the slowest).
  Initial fill before compute: ~34-41k cycles (yx) vs ~63k (old).
* 4x4: the DMA streams at the full **16 beats/cycle** while active; at small B it is active ~5k of
  each ~10k-cycle tile.
* ROB 64 (`r64_*`) vs 32: no change in cycles per tile at 4x4 B=1/2.

### 5.4 Per-core load delivery (new `[LDP]`, `build_split_vcs_lnp`, 4x4)

| run | words delivered / cycle / core | ROB occupancy (words, 4 ports) | latency = occ / rate |
|---|---|---|---|
| lnp_sb4_b1 (no split) | 0.62-0.64 | ~43 | ~67 cycles |
| lnp_sb4_b2 | 0.60-0.63 | ~39 | ~65 |
| lnp_sb4_b8 | 0.50 | ~21 | ~42 |

A core pulls ~2.4 B/cycle of W regardless of load size (128-512 B), vector length, K split or ROB
depth, far below what the ROB could hold (128 words). With KS FMAs per W element a core needs
16/KS B/cycle to keep the FPU busy, so 4x4 efficiency ~= KS/8 -- matching 12.8 / 27 / 57 / 93% at
KS 1/2/4/8. This per-core delivery ceiling is the open question (WORKLOG 2026-09-28).

### 5.5 Other effects worth reproducing

* **Tile-barrier tail, positional**: every K tile ends at a global barrier; groups finish in an
  order set by mesh position (finish time vs mean hop distance r = 0.79; centre first, corners and
  the east edge last, same order every tile). 8x8 B=16: ~3-4k of a 25k tile.
* **4x4 B=1 with K split**: 4 MSHR serve timeouts at the end of the first K tile, then ~8k cycles
  with no issue (once per run, ~3.6%). Not in the no-split run. Open.
* merge_reqs 4 vs 16 on the split MSHR: cycle-identical (kc3, kc4, B=32 over 185k cycles).

---

## 6. Probe reference

All probes print every 1000 cycles. QuestaSim prefixes every transcript line with `# ` (strip it
before matching; `calib_logs` already did). Per-group/per-channel CSV fields carry a **leading space
after `=`** on field 0 (`busy= 24016,...`) -- match with `=\s*`.

| tag | where | fields |
|---|---|---|
| `[FPU] pre|bench` | tb_fpu_util.svh | cyc, util (this period), cum (benchmark region), busy lane-cycles, grp_max/min, mshr_timeout (+delta), bankfull_bypass, core_spread, bar_* , insn_drift |
| `[FPUG]` | same | per-group busy lane-cycles, `denom` = period x lanes per group |
| `[STALLG]` | same | per group: ins / raw / lsu / acc / fence stall cycles (denom = cores x period) |
| `[MSHRG]`, `[MSHRCFG]` | tb / app | per-group MSHR counters; the CSR values actually applied |
| `[DMAP]` | tb_dma_profiling.svh | per group: busy, r (R beats), rstall, rwait, wstall, out (outstanding beats x cycles), arstall, chunks. Printed only in periods with DMA reads. |
| `[L2BW]` | same | per L2 channel: beats, ar, arstall, rstall (R waiting on the mesh) |
| `[AXIW]` | same (8x8 images from p3 on, lnp, rob64) | per group, port 0..4 = N,E,S,W,Eject: ohsk, ostall, ihsk, istall of the AXI wide router |
| `[AXIWP]` | same | the off-mesh periph router |
| `[LDP]` | tb_load_noc_probe.svh (**lnp image only**) | §5.4; per group rsp_x1000, occ_x10 |
| `[SUBNOC]` / `[SUBNOCD]` | same | per router class (wreq/resp/nreq) and parallel sub-NoC s = tile*ports+port: flits moved (hsk) and held (stall), summed over groups and N/E/S/W outputs; D = per direction |

**FPU util meaning changed**: in `build_split_vcs_lnp` (and every image built after 2026-09-28) the
`[FPU]`/`[FPUG]` numbers count **issued FPU operations** (fpnew input handshakes). In every other
image listed here they count `busy_o` = pipeline OCCUPANCY, which over-reads chained, data-starved
vector ops (4x4 B=1: 27% occupancy for a true 12.8%). Calibrate FPU activity against ideal/actual
cycles or against the lnp image, never against occupancy numbers at small B.

Useful tools: `scripts/qwen_perf_analyze.py` (loss budget, per-group util, stall shares, DMA
digest); cycles per tile = gaps between `[DMAP]` burst starts (a burst = consecutive periods with
DMA reads).

---

## 7. Caveats

* The uncommitted testbench files (`hardware/tb/tb_system_overview.svh`, `tb_load_noc_probe.svh`,
  edits to `tb_fpu_util.svh`, `mempool_tb.sv`) are probes only; no RTL change.
* 8x8 small-batch baselines (`sb_8_*`) use `qwen_span_align=4`, not the HEAD default.
* Arms killed on purpose (`kt1`, `dp1`, `x8pw`, `x8p2_b16/32`, `mr4_k_b16/64`, `mr16_k_b32`) still
  appear in `index.tsv` with partial data; they ran on older images and are superseded.
* Cycle counts: VCS and Questa are cycle-identical on this design (validated earlier).
