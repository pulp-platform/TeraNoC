# Group MSHR backend optimisation — campaign report

**Period covered:** 2026-09-10 → 2026-09-14
**Block:** `mempool_group_mshr` (`hardware/src/mempool_group_mshr.sv`)
**Status at close:** RTL frozen and tagged; out-of-context results below; full-group
place-and-route is the next step.

---

## 1. Objective and why this block

Close timing on the group MSHR at **1 GHz (TCK = 1.0 ns)**.

The block was selected from the 500 MHz placement shakedown of
`mempool_group_floonoc_wrapper`, which closed at WNS −9.44 ns. Of that block's **22,776
violating endpoints, 18,400 (80.8 %) were inside `mempool_group_mshr`**. The worst path
was **822 logic levels** at a dead-flat ~13.4 ps/level, 99.5 % ULVT, 2-input gates
throughout — the optimiser had nothing left to spend, so only RTL restructuring could
move it. Full prior analysis: `docs/mshr_timing_review_500mhz.md`.

The root cause identified there was a single **1,275-line `always_comb`**
(`mempool_group_mshr.sv:3175-4450`) that read-modify-wrote the 64-entry `mshr_d` array in
~10 sequential passes, several of them 32 deep over the (tile, port) request lanes.

---

## 2. Technology, corner and constraints

| item | value |
|---|---|
| technology | TSMC N7, `tcbn07_bwph240l11p57pd` (base SVT / LVT / ULVT) |
| tool | Synopsys Fusion Compiler **X-2025.06** |
| corner | `func_ssgnp_0p675v_m40c` — slow-slow, 0.675 V, −40 °C |
| parasitics | `cworst_CCworst_T` |
| analysis | POCV on (`POCV-Slew_Variation`), 3 sigma |
| mode / scenario | single mode `func`, `func_ssgnp_0p675v_m40c` |
| target period | **1.0 ns** |
| stop stage | `initial_opto` (post-placement optimisation) |
| output load | 15 fF max / 5 fF min |
| input drive | `BUFFD16BWP240H11P57PDSVT` |
| boundary delay | 0.20 ns input, 0.20 ns output (see §7 caveat) |
| false paths | `rst_ni` |

**Elaboration parameters.** The module's own defaults are wrong for this configuration
(`NumRemoteReqPortsPerTile` defaults to 2 but `mempool_pkg` computes 3), so the top is
elaborated explicitly:

```tcl
elaborate mempool_group_mshr -param "NumGroups=>16, NumTilesPerGroup=>16, \
    NumRemoteReqPortsPerTile=>3, NumRemoteRespPortsPerTile=>3"
```

**Synthesis define set** (the PnR configuration, distinct from the simulation one):

```
GROUP_MSHR_NUM=64            GROUP_MSHR_WAYS_PER_BANK=4     GROUP_MSHR_MERGE_REQS=4
GROUP_MSHR_BANK_HASH=3       GROUP_MSHR_BANK_SHIFT_SINGLE=9 GROUP_MSHR_BANK_SHIFT_BURST=7
GROUP_MSHR_BANK_BURST_BITS=1 GROUP_MSHR_BANK_PUBLISH=1      GROUP_MSHR_DRAIN_BEATS=2
GROUP_MSHR_DRAIN_FROM_Q=1    GROUP_MSHR_CACHE_RECLAIMABLE=0 GROUP_MSHR_CACHE_SELF_INVAL=1
GROUP_MSHR_CACHE_VICTIM_RR=1 GROUP_MSHR_RESP_WAIT_SUBS_SINGLE=1
GROUP_MSHR_STALL_ON_RESP=1   GROUP_MSHR_ENABLE_SINGLE=1     GROUP_MSHR_CFG_RUNTIME=1
GROUP_MSHR_ENABLE_STATS=0    GROUP_MSHR_SPILL_REQ_IN=0      GROUP_MSHR_HOLD_PRESCALE_W=6
GROUP_MSHR_HOLD_WINDOW_SINGLE=8191  GROUP_MSHR_HOLD_WINDOW_BURST=8191
GROUP_MSHR_SERVE_TIMEOUT=8191       TARGET_SYNTHESIS
NUM_GROUPS=16  NUM_X=4  NOC_PORT_HASH=7  NOC_ROUTER_REMAPPING=2
NOC_REQ_RDWR_CHANNEL_NUM=2  NOC_RESP_CHANNEL_NUM=2  NOC_VIRTUAL_CHANNEL_NUM=1
```

`MERGE_REQS` deserves a note: simulation ships **16**, synthesis uses **4**. It is an
elaboration constant that sizes the per-entry `sub_reqs` array, so 16 builds four times
the per-entry storage in all 64 entries. Until 2026-09-13 this value existed only inside
the OOC launcher and was never supplied by the config — it is now pinned in both backend
config flavours (`config/terapool_spatz4_fpu_backend_{4x4,8x8}.mk`).

---

## 3. Methodology

**Out-of-context synthesis as the iteration loop.** A full group place-and-route costs
about two weeks, which cannot steer RTL work. `mempool_group_mshr` instantiates only
`spill_register` and imports `mempool_pkg` / `cf_math_pkg` — no macros, no SRAM, 21 ports
— so it is a clean OOC target at 7–14 h per run. Every change therefore produced a
*measured* delta rather than an estimate.

**Stop at `initial_opto`, never `logic_opto`.** Pre-placement WNS is not trustworthy for
this design: placement roughly halves it. Every number in this report is
post-placement-optimisation.

**Simulation gate on every RTL change.** VCS, fixed workload
`hardware/elf/L_fp16_512x64x256.elf` on the 4×4 mesh, requiring an exact cycle count,
`retval 0` and zero assertion failures. VCS is used rather than QuestaSim for headless
runs (1.7× faster, cycle-identical).

**Equivalence assertions travel with the restructurings.** A transform that replaces one
form of logic with another carries an assertion comparing the two live during the run, so
it proves itself instead of being argued:

| assertion | proves |
|---|---|
| `cap_tree_equiv` | the capture arbiter tree names the same winners, ways and credits as the isolate it replaced |
| `hitway_compare_then_mux_equiv` | compare-then-mux hit lookup equals the mux-then-compare form |
| `req_bank_split_equiv` | the split burst/single bank hash equals the muxed-key form |
| `cut_tree_equiv`, `merge_applies_to_live_entry`, `gate_extra_dead_next_cycle` | arbiter cut and gating invariants |

**Variance is measured and respected.** Two runs of an identical netlist in this flow
differ by **±0.036 ns WNS and roughly 3× TNS**, driven by optimiser thread allocation.
Deltas inside that envelope are not claimed as improvements. This was established after
an early error in which a TNS change was attributed to ten commits whose RTL predated the
run that showed it.

---

## 4. RTL work carried out

17 commits touching the MSHR sources between `49d9feeb` and `d4988cd0`. By family:

**Compare-then-mux.** Run the hash or comparison for both classes in parallel and select
afterwards, instead of selecting first and computing after. The old form put a wide mux
and a ~20-bit comparator in series *after* the latest-arriving signal. Applied to the hit
lookup (`req_key_eq`), the bank hash (`mshr_bank_of` taking `key_burst`/`key_single`), and
the request-class decode.

**Removing variable array indices.** Each one forces synthesis to build an N-deep priority
mux on read or an N-wide scatter on write, because it cannot know which slot is touched.
Eight were removed in one pass (`91cc496c`…`97557d05`), covering the request, drain and
response cones.

**Arbiters that carry their payload.** The response-capture arbiter became a two-lowest
reduction tree carrying each winner's way and response credit with it, deleting a 32-wide
AND-OR recovery per bank (`fce8acd0`).

**Bank-scoped lookups** instead of whole-array scans; **clock-gate enables sourced from
registered state** (`mshr_q_valid`) rather than the deep combinational cone.

**Non-power-of-two ways.** `WaysPow2` guards at five sites plus modulo way-decode, making
48 entries / 3 ways a legal geometry (`8208ce1a`, `9562c06c`). The guard requires
power-of-two *banks*, not ways.

**Tile-contained bursts** (`caaf2621`, `f4332fbc`, with matching Spatz changes
`5119714`/`e35712d`). Bursts may now start at any bank provided they stay inside one tile
bank stripe. Previously an unaligned burst was clamped to a **single word**, turning a
12-word load into 12 separate requests; the producer now splits at the stripe boundary
instead. Containment is a producer-guaranteed protocol invariant checked by
simulation-only assertions in both consumers, so it adds no request-path logic.

---

## 5. Results

All runs: TCK 1.0 ns, `initial_opto`, `func_ssgnp_0p675v_m40c`.

### 5.1 Headline progression (64 entries / 4 ways)

| run | RTL | WNS (ns) | TNS (ns) | viol. EPs | area (µm²) | levels |
|---|---|---:|---:|---:|---:|---:|
| `ladder` | `49d9feeb` | −0.228 | −80.35 | 1852 | 103,774 | 886 |
| `ladder2` | `9562c06c` | −0.192 | −24.91 | 806 | 104,717 | 836 |
| `tenfix` | `f5b37d35` | −0.227 | −41.04 | 1025 | 103,940 | 857 |
| **`burst64`** | **`d4988cd0`** | **−0.180** | **−7.17** | **142** | **103,233** | **833** |

**TNS −80.35 → −7.17 and 1852 → 142 violating endpoints (−92 %).**

### 5.2 Area-reduced geometry (48 entries / 3 ways)

| run | RTL | WNS (ns) | TNS (ns) | viol. EPs | area (µm²) | levels |
|---|---|---:|---:|---:|---:|---:|
| `ladder48` | `9562c06c` | −0.214 | −22.50 | 908 | 89,932 | 903 |
| `tenfix48` | `f5b37d35` | −0.205 | −19.73 | 881 | 89,163 | 875 |
| `burst48` | `d4988cd0` | −0.222 | −38.90 | 836 | 90,039 | 920 |

48/3 is **12.8 % smaller** than 64/4 at the same RTL (90,039 vs 103,233 µm²).

### 5.3 Path-type decomposition — `burst64`

```
          Total   reg->reg    in->reg   reg->out    in->out
WNS      -0.180     -0.054     -0.030     -0.000     -0.180
TNS       -7.17      -0.55      -0.95     -0.000      -5.67
NUM         142         32         77          1         32
```

**The registered logic is essentially closed**: reg→reg is −0.054 ns over 32 endpoints,
TNS −0.55. **79 % of all remaining TNS is one combinational path.**

### 5.4 Violating endpoints by function — `burst64`

| family | n | WNS | TNS | % TNS |
|---|---:|---:|---:|---:|
| `req_ready_o` — in→out accept path | 32 | −0.180 | −5.68 | **79.2** |
| `replay_*_q` — replay walker | 33 | −0.030 | −0.52 | 7.3 |
| `mshr_q_valid` — clock-gate enable | 8 | −0.054 | −0.41 | 5.8 |
| `mgb_q_*` — merge arbiter cut | 19 | −0.026 | −0.26 | 3.6 |
| `agb_q_*` — alloc arbiter cut | 19 | −0.015 | −0.15 | 2.1 |
| `mshr_q.state` — entry FSM | 11 | −0.016 | −0.08 | 1.1 |

Slack distribution: **32 endpoints at −0.180 … −0.150, then nothing until −0.054**, and
84 of the 142 are within 20 ps of closing. The violation is one clean wall plus noise.

For contrast, `burst48` remains distributed — 309 response-capture and 191 entry-FSM
endpoints, 318 in the −100…−50 ps band.

### 5.5 Critical path — `burst64`

```
Startpoint: cfg_i[23]                  (input port clocked by clk)
Endpoint:   group_mshr_req_ready_o[25] (output port clocked by clk)
Path group: in2out_default

  input external delay      0.200   ->  0.209
  ... combinational accept cone ...   ->  0.980   (0.771 ns of logic)
  data required time                      0.800   (1.000 - 0.200 output delay)
  slack (VIOLATED)                       -0.180
```

The path is `group_mshr_req_valid_i` / `req_i` / `cfg_i` → the request decode → bank hash →
per-bank arbitration → accept → `group_mshr_req_ready_o`. It is **input-to-output**, so it
can be neither retimed nor pipelined as currently structured.

`cfg_i[23]`/`[24]`/`[27]`/`[28]` are the `bank_shift_burst` and `bank_shift_single` CSR
fields — a quasi-static runtime configuration input feeding the bank hash. These paths are
**co-critical** with the request paths (within 1–2 ps), not worse, so removing them buys
nothing: the length is in the shared downstream cone, not the startpoint.

### 5.6 Cell and utilisation data — `burst64`

| metric | value |
|---|---|
| total cells | 930,711 |
| combinational | 912,565 |
| sequential | 18,146 |
| clock-gating elements | 1,130 |
| ungated registers | 206 (1.21 %) |
| combinational area | 90,539 µm² |
| buf/inv area | 14,563 µm² |
| sequential area | 12,693 µm² |
| total cell area | 103,233 µm² |
| VT mix | **93.79 % ULVT**, 4.10 % LVT, 2.11 % SVT |

The 93.8 % ULVT share is unchanged from the 500 MHz shakedown and confirms the block is
still leakage-expensive and speed-limited rather than drive-limited.

---

## 6. Functional verification

Gate on the final RTL (`d4988cd0`), VCS, `L_fp16_512x64x256.elf`, 4×4:

| metric | frozen baseline (`fce8acd0`) | current (`d4988cd0`) |
|---|---:|---:|
| cycles | 6993 | **6776 (−3.1 %)** |
| retval | 0 | 0 |
| fatals / assertion failures | 0 | 0 |
| burst merge share | 23040/30720 = 75.0 % | 23040/30720 = **75.0 %** |
| single merge share | 107520/122880 = 87.5 % | 107520/122880 = **87.5 %** |

The merge counters are **byte-identical**, so the tile-contained burst change did not
disturb coalescing; the 217-cycle gain comes from loads that previously fell back to
single-word traffic now issuing as real bursts. `burst_within_tile` and the expander's
`burst_contained` assertion never fired.

---

## 7. Caveats

**7.1 The two geometries disagree.** Identical RTL moved 64/4 **0.047 ns better** and 48/3
**0.017 ns worse** than their respective baselines — opposite signs. Both deltas are partly
inside the ±0.036 ns / 3× TNS variance envelope. The 64/4 endpoint collapse (1025 → 142)
is larger than variance has previously produced and is probably real, but the magnitude
should be reproduced before it is quoted as settled.

**7.2 The boundary budget is optimistic, not conservative.** The 0.20 ns in / 0.20 ns out
is a logic-only reconstruction:

* input — driver is `mempool_tile.sv:846 i_tcdm_master_req_register`, a non-bypassed
  `spill_register` reaching the port through pure wire assigns. Launch is clk-to-Q 0.172 +
  output mux ~0.031 = **0.203**.
* output — receiver is that same spill register's `ready_i`: ~0.02 ns of `b_fill` logic
  plus a clock-gate enable check (~0.091 ns tighter than a flop D setup) ≈ **0.14**.

Neither figure carries **any** interconnect allowance, for wires spanning 16 tiles to one
block and back. The true boundary cost is ≥ 0.40 ns, so the OOC WNS understates the
problem. Measuring the real numbers from a placed group is outstanding.

**7.3 These are block-level numbers.** The ~19 % of the group's violating endpoints
outside the MSHR have not been revisited since the 500 MHz run and will be worse at 1.0 ns.

**7.4 Flow hazard found and fixed.** Fusion Compiler places analysed units in a
`HDL_LIBRARIES/WORK` directory relative to its working directory, which is **shared** by
every run launched from the same place. Two runs whose elaboration constants differ
therefore overwrite each other's packages: a `burst64` launched 5 s before a `burst48`
linked a `req_decode` compiled against the 48-entry package and died with `LNK-012` width
mismatch on `req_i` (`MshrTagWidth` is 7 bits at 64 entries and 6 at 48). Fixed by giving
each run a private working directory (`run_ooc6.sh`); the earlier `tenfix` pair only
survived because it happened to be staggered by 37 minutes.

**7.5 Elaboration cost of non-power-of-two ways.** 48/3 elaborates ~5× slower than 64/4
(1:00:06 vs 12:53 for the same design size) because every `% 3` and `/ 3` on entry and way
indices must be constant-folded at each generate site. This is tool time, not silicon: the
arbiter families that carry that arithmetic show no timing penalty.

---

## 8. Status and next step

RTL is frozen at `d4988cd0` and tagged `mshr-freeze-20260912`. The backend config flavours
are pinned to the synthesis define set, and the Spatz revision read by synthesis
(`e35712d`) now matches the one simulated.

**The remaining gap is one structural path, not distributed logic depth.** The
`req_ready_o` accept path has ~0.771 ns of logic against a 0.60 ns window. Two ways
forward:

1. **Cut it.** The MSHR already has an optional input spill register (`SPILL_REQ_IN`,
   currently 0) which would make `ready_o = !a_full_q || !b_full_q` — a registered output.
   Estimated cost ≈ +4 % area (32 lanes × ~166 flops at 0.70 µm²/flop) and one cycle of
   request latency, throughput-neutral because a spill register is two-deep. It also
   converts an in→out path, which cannot be retimed, into a reg→reg path that can.
2. **Shorten the shared accept cone** — request decode → bank hash → arbitration → accept.

**Next milestone:** full-group place-and-route of `mempool_group_floonoc_wrapper`, run for
*measurement* rather than closure — real boundary delays, the non-MSHR violation
distribution, and whether `req_ready` remains critical once placed.
