# Scale-up plan — configurable mesh (4×4 → 8×8 → …)

Status: **proposal, nothing implemented.** Written 2026-08-03, after the 4×4 MSHR
campaign reached 96.8 % FPU utilisation on `128×1024×512`.

Goal: make the mesh size a **configuration parameter** — L1 (TCDM) NoC and L2
(AXI) NoC together, with group count, core count and L1 capacity following — so
the whole scaling curve of FPU utilisation and total compute can be measured.
The 4×4 design stays the committed default throughout and is the regression gate
for every phase.

Supersedes the earlier `scaleup_8x8_plan.md` (fixed 8×8 target).

---

## 1. What is configurable, and why

### 1.1 The mesh dimensions must be powers of two

The group index in a memory address is a **bit-field extract**
(`mempool_tile.sv:1192`):

```systemverilog
tgt_group_id = addr[ByteOffset + $clog2(NumBanksPerTile) + $clog2(NumTilesPerGroup)
                    +: $clog2(NumGroups)];
```

and that flat index is then **bit-cast** straight into mesh coordinates
(`mempool_group_floonoc_wrapper.sv:285`, and 6 other sites):

```systemverilog
dst_id: group_xy_id_t'({tcdm_master_req[i][j].tgt_group_id, 1'b0})
```

So mesh coordinates are not computed anywhere — they *are* address bits, with
`gid = x·NumY + y`. Consequently `NumX`, `NumY` and every other field
(banks/tile, tiles/group) must be powers of two. This is a property of MemPool's
word-interleaved shared L1, not something this branch introduced.

**5×5, 6×6, 7×7 are therefore not a config change.** They would require replacing
the bit extract with a constant modulo and the bit-cast with a constant divide,
both on the L1 request path, plus reworking the MSHR bank hash, the kernel's
word-interleave assumptions and `arch.ld.c`. The alternative — round the group
field up to the next power of two and leave slots unmapped — punches holes in L1
that any contiguous array would straddle. Not worth it.

### 1.2 The ladder

Rectangular power-of-two meshes are fine, so the sweep doubles each step:

| mesh | groups | cores | L1 | peak flop/cyc | XY diameter | min legal M |
|---|---|---|---|---|---|---|
| 2×2 | 4 | 64 | 1 MB | 512 | 2 | 32 |
| 2×4 | 8 | 128 | 2 MB | 1024 | 4 | 64 |
| **4×4** | **16** | **256** | **4 MB** | **2048** | **6** | **128** |
| 4×8 | 32 | 512 | 8 MB | 4096 | 10 | 256 |
| 8×8 | 64 | 1024 | 16 MB | 8192 | 14 | 512 |
| 8×16 | 128 | 2048 | 32 MB | 16384 | 22 | 1024 |
| 16×16 | 256 | 4096 | 64 MB | 32768 | 30 | 2048 |

Seven points spanning 64× of compute. `min legal M = num_groups × KERNEL_SIZE`.

### 1.3 What stays invariant (why this is tractable)

Holding **cores/group = 16** (1 core/tile, 16 tiles/group) keeps the entire
group-level microarchitecture fixed at every mesh size:

* `NumBanksPerGroup = NumBanks/NumGroups = 256` — **independent of mesh size**,
  so `TCDMAddrWidth`, the tile crossbar and the L1 word layout never move.
* The group MSHR keeps 16 tiles × 2 remote req ports = 32 concurrent slots →
  `group_mshr_num=64`, `ways_per_bank=4`, the bank hash, ParityDrain and all
  tuned knobs carry over **with the same derivation rules**.
* The within-tile word field stays 8 bits → `group_barrier_word=240` still places
  the barrier window at the top of L1 with 16 words spare, at every size.
* `DmaBurstLen = (NumBanksPerGroup/NumDmasPerGroup)/DmaNumWords`
  (`mempool_pkg.sv:261`) is likewise invariant.

What actually changes: router count, group address field width, mesh diameter,
L2 channel count, and the software's minimum legal `M`.

---

## 2. The two NoCs

They are **separate overlaid meshes on the same grid**, with different routing:

```
                     ┌─ TCDM / L1 NoC ────────────────────────────────┐
core → tile → group ─┤  6× floo_router per group (narrow-req, wide-req,│
                     │  resp), XY routing, tables in routing_table_pkg │
                     └────────────────────────────────────────────────┘
                     ┌─ AXI / L2 NoC ─────────────────────────────────┐
group DMA ──┐        │  1× floo_nw_router + floo_nw_chimney per group, │
RO icache ──┴────────┤  512b wide AXI, SOURCE routing, all-pairs table │
                     │  in the floogen-generated package               │
                     └────────────────────────────────────────────────┘
                          → perimeter chimney → axi2mem → tc_sram L2 bank
```

The L2 NoC was surveyed second and turns out to hold the worse scaling terms.

---

## 3. Blockers, by subsystem

### 3.1 Group-count ceiling

| file | what |
|---|---|
| `hardware/src/mempool_pkg.sv:21` | `MAX_NumGroups = 16` |
| `hardware/src/ctrl_registers.sv:185,188` | `$error` if `NumGroups > MAX_NumGroups`, and a mismatch check |
| `hardware/src/control_registers/control_registers.hjson:20,48` | `MAX_NumGroups` param + wake-up register `count` |
| `hardware/src/control_registers/control_registers_reg_pkg.sv:11` | **generated** — regenerate from the hjson, do not hand-edit |

`ctrl_registers` allocates `MAX_NumGroups` wake-up registers **unconditionally**,
so raising it to a global literal (256) taxes every config. **Derive it from
`NumGroups`** instead.

### 3.2 Even-split coordinate type

`mempool_pkg.sv:405` gives x and y equal widths of `idx_width(NumGroups)/2`.
Exact only when `idx_width(NumGroups)` is even — 4, 16, 64, 256. At 32 groups it
silently yields 2 bits per axis, too narrow for an 8-wide axis. Fix:

```systemverilog
typedef struct packed {
  logic [idx_width(NumX)-1:0] x;
  logic [idx_width(NumY)-1:0] y;
  logic                       port_id;
} group_xy_id_t;
```

and assert, at elaboration:

```
NumX * NumY == NumGroups
NumX, NumY both powers of two
idx_width(NumX) + idx_width(NumY) == idx_width(NumGroups)   // keeps the bit-cast valid
```

That last assert is the one that would have caught 4×8 today.

### 3.3 TCDM routing table — NOT a blocker for mesh configs (measured 2026-08-04)

The plan originally called this "the largest new-code item" with a non-negotiable
bit-identical gate. **That rested on a false premise: the table is not used by
mesh configs.**

`routing_table_pkg::RoutingTables` is referenced only inside
`if (NocTopology == 1) begin: gen_torus` (`mempool_group_floonoc_wrapper.sv`
:829, :887, :944). With `noc_topology = 0` the `gen_2dmesh` branch instantiates
`floo_router` with `RouteAlgo = XYRouting`, `xy_id_i = group_xy_id`, and
`id_route_map_i` tied to `'0`.

`floo_route_select`'s XY branch computes the direction from `id_in.x/y` against
`xy_id_i.x/y` — plain comparisons on the struct fields, no table and no baked
dimensions. **It already scales to any mesh size**, provided the x and y fields
are sized correctly, which is exactly what §3.2 (Phase 1a) fixed.

This also explains why the committed table decodes as a *torus* table (40/256
violations against torus-XY, 80 against mesh-XY, no encoding reproducing it
exactly): torus is its only consumer, so nothing in the mesh path ever noticed.

**Consequence:** a TCDM table generator is needed only if `noc_topology = 1` is
chosen — which §8 still lists as an open decision. It is off the critical path.

### 3.4 L2/AXI NoC — source routing is O(N²·diameter)

`generated/floo_terapool_noc_pkg.sv`: `route_t = logic [22:0]`,
`RoutingTables = route_t [34][34]` — a precomputed path per endpoint pair,
carried in every AXI header.

| mesh | endpoints | est. `route_t` | table |
|---|---|---|---|
| 4×4 | 34 | 23 b | ~26 kbit |
| 8×8 | 98 | ~48 b | ~460 kbit |
| 16×16 | 322 | ~96 b | ~10 Mbit |

**Fix: switch the AXI network to XY routing.** floogen supports it
(`floogen/model/routing.py:28`, `RouteAlgo.XY = "XYRouting"`); the yml's
`routing: route_algo: "SRC"` becomes `"XY"`. The table disappears and the header
carries `id_t` (6 b) instead of `route_t`. One catch: the router is instantiated
with `.id_i('0)` (`mempool_group_floonoc_wrapper.sv` ~1046) — unused under source
routing, but XY needs the router's real (x,y) driven there.

**This is mesh-size independent and can be done and validated on 4×4 first.**

### 3.5 L2 channel count — four coincidences that all break

`mempool_system.sv:42` — `localparam NumAXIMasters = NumGroups;` — sizes the AXI
chimneys, the L2 adapters and the L2 bank indexing. Today four unrelated
expressions all evaluate to 16:

| | 4×4 | 8×8 |
|---|---|---|
| `NumAXIMasters = NumGroups` | 16 | **64** |
| perimeter attach points `2·(NumX+NumY)` | 16 | **32** |
| `l2_banks` (config knob) | 16 | 16 |
| yml `hbm: array: [16]` | 16 | 16 |

All four diverge above 4×4, and the failure is *silent*: surplus chimneys tie
off, so it elaborates and fails later as a hang or wrong data during DMA fill.

Also: `gen_l2_adapters` (`mempool_system.sv:659`) loops `NumAXIMasters` and drives
`bank_req[i]`/`bank_addr[i]`; `gen_l2_banks` (line 702) loops `NumL2Banks`. They
are 1:1 by index with **no assert**, so `l2_banks` must equal `NumAXIMasters` —
setting `l2_banks=32` today would leave 16 SRAMs undriven.

And `l2_size` is duplicated: `.mk` says 16 MB, yml says
`hbm addr_range: base 0x8000_0000, size 0x0010_0000` × 16 = 16 MB. No cross-check;
the SAM in the generated package is the authority.

Fix: introduce an explicit `NumL2Channels`, decouple from `NumGroups`, assert
against the perimeter count, derive `l2_banks` from it, and give `l2_size` a
single source of truth shared by the `.mk` and the yml generator.

### 3.6 Perimeter geometry (both NoCs)

`terapool_cluster_floonoc_wrapper.sv:118-270` indexes AXI ports with literals
baked to 16 channels on a 4×4 ring: `floo_axi_req_i[y+12]` (east), `[5-x]`,
`[x+6]`, `[13-x]` (south/north), and an `x < NumX/2` split at line 253.

Fix: one `perimeter_channel_idx(x, y, dir)` function in `mempool_pkg`, used by
**both** the wrapper and the yml generator so they cannot disagree. An 8×8 mesh
has 28 perimeter routers against 12, so HBM placement is a redesign, not a
rescale — 8 channels per edge maps cleanly at 32 channels.

### 3.7 Address map and linker

The group field grows with `log2(NumGroups)`, moving everything above it.

* `software/runtime/arch.ld.c:21` hardcodes `GROUP_BARRIER_WORD * 16384`. That
  16384 is `4 · banks_per_tile(16) · tiles_per_group(16) · num_groups(16)`.
  **Derive it** from the existing defines.
* `scripts/gemm_autotune.py:162` has the *same* literal
  (`l1_bytes = gbar_word * 16384`). The script already parameterises
  `--num-groups` / `--num-cores`; only this stride needs deriving.
* `group_barrier_word = 240` needs no change (word field stays 8 bits) — but
  re-verify `GBAR_BASE_WORD` in the kernel and the L1 truncation point.

---

## 4. Phases

Ordered so that each one has a working design to regress against.

| # | phase | gate |
|---|---|---|
| **0** | **AXI NoC SRC → IdTable on 4×4** (§3.4) — *done 2026-08-03, see §9* | 4×4 matmul cycle-count unchanged — **not met, +1.24%** |
| 1a | Coordinate type split & elaboration guards (§3.2) — **done 2026-08-04** | **passed: 122,051 cycles, bit-identical; guard verified to fail a bad config** |
| 1b | Group-count ceiling (§3.1) — **blocked, see §10** | needs a `reggen` step in the build; not bit-identical |
| 2 | TCDM routing-table generator (§3.3) | 4×4 regeneration **bit-identical** |
| 3 | L2 channel decoupling (§3.5) + perimeter function (§3.6) + yml/config generator | 4×4 unchanged; 8×8 elaborates |
| 4 | Address map / linker derivation (§3.7) | 1024-core `hello_world` + barrier microbenchmark, CMS armed |
| 5 | Bring-up ladder: Questa elaboration → `hello_world` → barrier → smallest legal matmul → full sweep | each rung green before the next |
| 6 | Software shape ladder + knob re-derivation (§5) | tuner agrees with measurement on 4×4 |
| 7 | Scaling measurement + docs (§6) | results folded into `docs/benchmarks/` |

A one-command config generator emitting
`config/terapool_spatz4_fpu_<X>x<Y>.mk` + matching floo yml lands in phase 3, so
adding a ladder rung afterwards is trivial.

---

## 5. Software scaling

`main.c:202-290` is already fully parameterised on `NUM_GROUPS` — **no kernel
code change**. What moves is the useful shape set, by the same factor as the
group count:

```
dim_group     = M / num_groups
split_m_count = dim_group / KERNEL_SIZE(8)
split_p_count = cores_per_group(16) / split_m_count
A shared by split_p_count,  B shared by split_m_count
```

At 8×8 (64 groups), the 4×4 table shifts up by 4×:

| M | dim_group | A-share | B-share | 4×4 equivalent |
|---|---|---|---|---|
| 512 | 8 | 16 | 1 | M=128 (the 96.8 % point) |
| 1024 | 16 | 8 | 2 | M=256 |
| 2048 | 32 | 4 | 4 | M=512 |
| 4096 | 64 | 2 | 8 | M=1024 (the ~0.47× regression zone) |

* Design rule translates directly: **raise N, keep M ≤ 4·(mesh scale) — i.e. keep
  `dim_group ≤ 32`.**
* L1 usable grows with core count (3.61 MB → ~15.7 MB at 8×8), lifting the N
  ceiling that capped the 4×4 design at ~97 %. This is the main reason to expect
  better *utilisation*, not just more throughput.
* `shift_burst ≥ 5` still forbids fewer than 32 words per core along P.

---

## 6. Measurement

Two comparisons, both needed:

* **Iso-shape** — same M/N/P across mesh sizes → speedup against the ideal.
  Limited range: the minimum legal M rises with group count, so only adjacent
  rungs share shapes.
* **Iso-work-per-core** — 4×4 `128×1024×512` vs 8×8 `512×1024×512` vs 16×16
  `2048×1024×512`. This is the one that stays meaningful across the whole ladder,
  and it answers the real question: **does the group MSHR still cover the latency
  when the diameter goes 6 → 14 → 30 hops?**

Report FPU utilisation *and* absolute flop/cycle per rung. Fold into
`docs/benchmarks/gemm_results.md` via its regeneration script, keeping the 4×4
numbers as the reference row.

---

## 7. Risks, ranked

1. **TCDM routing table correctness** — a wrong table is a routing deadlock that
   costs hours per discovery. The bit-identical 4×4 gate is the mitigation.
2. **L2 bandwidth per core collapses if the channel count is held.** 16 channels
   × 512 b for 256 cores = 4 B/core/cyc; at 8×8 with 16 channels it is 1. The
   timed matmul is L1-resident so this hits DMA fill and icache refill, not the
   kernel — but fill is a fixed cost growing with the working set.
3. **Simulation cost.** The Verilator model grows with core count; Questa
   elaboration is already 7+ min at 256 cores. Verilator for sweeps, Questa for
   elaboration authority and assertion runs (Verilator does **not** enforce
   `ifndef VERILATOR` assertions or elaboration `$error` — it will happily run an
   illegal config).
4. **Mesh latency vs MSHR window.** `group_mshr_serve_timeout=255` and the hold
   windows were tuned against a 6-hop diameter. Re-derive per rung, do not inherit.
5. **Small rungs are not currently bootable.** Only `terapool_spatz4_fpu` boots on
   this branch; the smaller Spatz configs wedge at a host-chimney assertion. 2×2
   and 2×4 need that debugged before they can join the ladder.

## 8. Open decisions

* **L2 channel count per rung.** Constant (16), constant-per-core (scales with
  cores), or constant-per-edge (`2·(NumX+NumY)`)? This changes what the scaling
  curve actually measures — the third keeps the mesh geometry uniform and is the
  natural default.
* **Torus?** `noc_topology=1` roughly halves the diameter (8×8: 14 → 8 hops) for
  the cost of wrap links. Decide before phase 2, because it changes the routing
  generator and the perimeter placement.
* **Ladder extent.** 16×16 (4096 cores, 64 MB L1) may exceed practical simulation
  budget; 8×16 might be the last measurable rung.

---

## 9. Phase 0 outcome (2026-08-03)

**Done and verified functionally; the cycle gate was not met.** Not committed.

XY was attempted first and **rejected**: floogen's `compile_ids` requires every
router to carry a mesh array index, and `periph_router` has none — and the three
endpoints hanging off it (`periphs`, `host`, `hbm[5]`) share one coordinate,
which XY cannot disambiguate. Making XY work means restructuring the topology
*and* the matching wiring in `mempool_system.sv`. **IdTable** achieves most of the
benefit on the unchanged topology, so that is what shipped.

| | SRC (before) | IdTable (after) |
|---|---|---|
| generated package | 1,383 lines | **157 lines** |
| `RoutingTables[34][34]` | present | **gone** |
| flit header dst field | `route_t`, 23 bits | **`id_t`, 6 bits** |
| `Sam` / `ep_id_e` | — | **byte-identical** |
| Questa assertions | 0 | **0** |
| cycles (256×512×256) | 122,051 | **123,567 (+1.24%)** |

The header narrowing is the durable win: it applies to every AXI link in the
mesh, and unlike the source-routing table it does **not** grow with diameter.

**New tool — `hardware/scripts/gen_floo_route_tables.py`.** floogen's own ID
tables are unusable here (subordinate destinations only → responses to the
manager-only groups are unroutable) and its `nx.shortest_path` turn model is
neither XY nor YX, which admits routing deadlock. The generator takes topology
from floogen but computes strictly XY dimension-ordered rules and verifies every
(router, destination) pair reaches delivery before emitting. Verified on all 8
configs including 2×2 meshes — i.e. the mesh-independence Phase 3 needs is
already demonstrated.

Rules per router are 5–12 before equalising, versus floogen's 10–23, because
`gid = x·NumY + y` makes each direction's destinations a contiguous id range.
That property holds at any mesh size, so the table stays small as the mesh grows.

### Turn model: measured, and my first justification was wrong (2026-08-04)

Two variables were bundled in the first attempt — the routing **mechanism**
(SourceRouting → IdTable) and the routing **policy** (shortest-path → XY). A
one-variable control run separated them:

| model | mechanism | turn model | cycles |
|---|---|---|---|
| base | SourceRouting | shortest-path | 122,051 |
| sp | **IdTable** | shortest-path | **122,051** |
| id2 | IdTable | strict XY | 123,567 |

**SourceRouting → IdTable is exactly cycle-neutral.** The whole +1,516 was the
turn model.

I had justified XY by counting 72 XY-violations and 72 YX-violations in floogen's
shortest-path routing and concluding it "admits cyclic channel dependencies".
**That was wrong** — violating dimension-order is not the same as having a cycle.
A CDG cycle needs a complete four-turn rotation; measured, shortest-path uses only
`N→E, S→E, W→N, W→S` — at most 2/4 of either rotation — and its channel dependency
graph is **acyclic**, on the req, rsp and wide networks and even for a
hypothetical all-to-all pattern. The restriction to group↔edge traffic isn't even
needed: routing is destination-based, so the turn set is the same either way.

The same measurement punctures "strictly XY, deadlock-free by construction": XY
also makes an `N→E` turn here, from the three endpoints anchored at the off-mesh
`periph_router` at (0,-1), whose traffic enters the mesh heading north and must
then turn east. Still acyclic, but analytically rather than structurally.

**Decision: ship shortest-path** (`FLOO_TURN_MODEL ?= shortest`). Phase 0 then has
**zero behavioural change** — same paths and same cycles as the committed design —
while still shrinking the package 1,383 → 157 lines and the header 23 → 6 bits.
For a refactor underneath a scale-up campaign that is the right property: routing
is not a suspect when something breaks three phases later.

**What makes it safe is a gate, not an argument.** The generator now builds the
channel dependency graph over every (router, destination) pair and **refuses to
emit** a table containing a cycle. Shortest-path acyclicity is an accident of
topology and `nx` tie-breaking, so it is verified on every regeneration rather
than assumed. `hardware/generated/floo_terapool_route_table_pkg.sv` is now tracked
in git for the same reason — a silent routing change must appear in a diff.

`--turn-model xy` remains one variable away: acyclic by construction, ~half the
rules per router (12 vs 23), 1.24% slower here.

### Verified

| | committed | Phase 0 |
|---|---|---|
| cycles (256×512×256) | 122,051 | **122,051** |
| Questa assertions | 0 | **0** |
| boots / traffic | yes | **yes** |
| package | 1,383 lines | **157 lines** |
| header dst field | 23 bits | **6 bits** |
| deadlock check | none | **gated on every regeneration** |

### Open

* Only `terapool_spatz4_fpu` was verified. The other 7 ymls were converted for
  consistency but are unverified and do not boot on this branch for unrelated
  reasons.
* At 8×8 the turn model must be re-decided: XY's rules-per-router advantage and
  its concentration penalty both grow, and shortest-path's acyclicity must be
  re-checked. The gate does that automatically; the cycle cost needs measuring.


---

## 10. Phase 1b blocker: MAX_NumGroups needs a register-file regeneration step

The plan said "derive `MAX_NumGroups` from `NumGroups` instead of a global
literal". That is not sufficient:

* it sizes the `wake_up_tile` **multireg** in `control_registers.hjson`
  (`count: "MAX_NumGroups"`) — it decides how many registers exist, not just a
  bound;
* `control_registers_reg_pkg.sv` is **generated** with the value baked in, and
  SystemVerilog package parameters cannot be overridden at instantiation;
* `reggen`/`regtool` live only under
  `hardware/deps/register_interface/vendor/patches/` and are referenced by no
  Makefile — the build has no regeneration step;
* at 64 groups the block outgrows `BlockAw = 8` (256 B), so the address map moves
  and the software side has to be checked.

**The ceiling is already loud — measured.** `ctrl_registers.sv:107` imports
`mempool_pkg::NumGroups`, and line 186 compares it against the generated
`MAX_NumGroups`. A 4×8 / 32-group / 512-core elaboration aborts with exactly:

```
# ** Error: [ctrl_registers] Number of groups exceeds the maximum supported.
#    Scope: mempool_tb.dut.i_ctrl_registers.genblk4  ctrl_registers.sv:186
# Optimization failed        Errors: 1
```

So "derive `MAX_NumGroups` from `NumGroups`" — the plan's original suggestion —
would add a redundant second error and make the name inaccurate. **Do not do it.**

The only real work is wiring `reggen` into the build and regenerating, which
belongs at **Phase 3**, where the perimeter and L2 channel count are reworked and
the register map is disturbed anyway.

The same probe confirmed the new `group_xy_id_t` guards stay **silent** on a legal
4×8 mesh, and that `MAX_NumGroups` is the **first** blocker at 32 groups. `vopt`
stops at the first error, so the rest of the blocker list still needs enumerating
by neutralising each in turn.
