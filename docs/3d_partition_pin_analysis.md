# 3D Partitioning — tier-to-tier pin count per partition scheme

**Status: analysis (2026-08-13).** All interface widths below are *measured* from the elaborated
RTL (a `$bits()` probe compiled against `mempool_pkg` with the real build defines), not estimated.
Baseline config `terapool_spatz4_fpu` (4×4 mesh, 256 cores); an 8×8 (1024-core) column is given
for scale-up.

## 1. Measured base data

### 1.1 Geometry (both configs unless noted)

| quantity | 4×4 | 8×8 |
|---|---|---|
| groups (mesh) | 16 (4×4) | 64 (8×8) |
| tiles / group | 16 | 16 |
| cores / tile · data ports / core | 1 · 5 | 1 · 5 |
| **banks / tile** | **16** | 16 |
| banks / group | 256 | 256 |
| banks total | 4096 | 16384 |
| `TCDMAddrMemWidth` (bank addr) | 8 | 8 |
| remote req / resp ports per tile | 3 / 3 (idx0 = intra-group, idx1-2 = NoC) | 3 / 3 |
| NoC req / resp channels per tile | 2 / 2 | 2 / 2 |

> Note: 16 banks/tile (= `NumFUsPerCore`(4) × `BankingFactor`(4) × `NumCoresPerTile`(1)), **not** 4.
> The address-decode note in `CLAUDE.md` (bank field = 2 b) is stale for this flavour.

### 1.2 Interface widths (payload bits; add 2 for valid+ready per channel)

| interface | 4×4 | 8×8 |
|---|---|---|
| `tcdm_master_req_t` | 82 | 84 |
| `tcdm_master_resp_t` | 53 | 53 |
| `tcdm_slave_req_t` | 82 | 84 |
| `tcdm_slave_resp_t` | 61 | 63 |
| `floo_tcdm_rdwr_req_t` (mesh req flit) | 93 | 97 |
| `floo_tcdm_resp_t` (mesh resp flit) | 68 | 72 |
| **`floo_tcdm_req_if_t`** (one mesh direction) | **3040** | 3168 |
| **`floo_tcdm_rsp_if_t`** (one mesh direction) | **2240** | 2368 |
| AXI mesh `floo_req_t` / `floo_rsp_t` / `floo_wide_t` | 114 / 109 / 618 | same |
| `tcdm_dma_req_t` / `tcdm_dma_resp_t` (per tile) | 602 / 525 | same |
| `axi_tile_req_t` / `axi_tile_resp_t` (per tile) | 717 / 528 | same |
| **SRAM bank macro** (req+we+addr8+wdata32+be4+rdata32) | **78** | 78 |
| **core data port** (addr32+w1+amo4+data32+strb4+id6+v/r2 ; pdata32+err1+pid6+v/r2) | **122** | 122 |

Key structural fact: the L1 mesh is **fine-grained — 16 router columns per group** (one per tile)
× 2 channels, so a single mesh direction already bundles 16·2·95 = 3040 (req) + 16·2·70 = 2240
(resp) wires. This dominates every scheme that cuts NoC links.

### 1.3 Derived per-unit costs (4×4)

| unit | wires |
|---|---|
| one mesh **edge** (both neighbours, req+rsp, TCDM) | 2·(3040+2240) = **10 560** |
| … + AXI/L2 mesh (`req+rsp+wide`, both ways) | +2·841 = **12 242** |
| tile group-facing interface, **total** | **3248** |
| ├ intra-group xbar (port 0) | 286 |
| ├ router-tile xbar (ports 1-2) | 572 |
| ├ dma-tile xbar | 1131 |
| ├ tile AXI (L2/icache refill) | 1245 |
| └ misc (tile_id, wake, clk/rst/scan) | 14 |
| tile bank side (16 × 78) | **1248** |
| tile core side (5 × 122) | **610** |
| router local ports per group (inject+eject, all 16 columns × 2 ch) | **10 560** |

## 2. Scheme 1 — group boundary, 3D mesh

Fold the 4×4 mesh into **4×2×2**: 8 groups per tier, one vertical (z) link per (x,y) column.

| variant | z-links | wires / link | **total** |
|---|---|---|---|
| TCDM + AXI mesh both 3D | 8 | 12 242 | **97 936** |
| TCDM mesh 3D only (AXI stays planar) | 8 | 10 560 | 84 480 |
| *planar bisection* (keep 2D topology, fold die, cut one row) | 4 | 12 242 | 48 968 |

8×8 → 8×4×2: 32 z-links × 12 754 = **408 128**.

**This is by far the cheapest partition** — the cut plane crosses only whole-group NoC links, which
is exactly what a mesh is designed to serialize. It also needs no RTL surgery: the router already
has N/E/S/W ports; a 3D mesh needs a 5th/6th (Up/Down) port per router (`NumDirections` 5 → 7) and
a 3D routing function (XYZ), which is a contained change in the FlooNoC router + route table.

## 3. Scheme 2 — tile boundary (8 tiles up / 8 down per group)

Every crossing is a tile↔group-interconnect link (intra-group xbar + router-tile xbar + dma-tile
xbar), i.e. **3248 wires per crossing tile**.

| model | crossings / group | per group | **chip (16 groups)** |
|---|---|---|---|
| A: xbars centralized on one tier; the 8 far tiles connect down | 8 tiles | 25 984 | **415 744** |
| B: each xbar split half/half; every tile must reach the far half | 16 tiles | 51 968 | **831 488** |

8×8, model A: 8 × 3266 × 64 = **1 672 192**.

**Observation that matters for the trade-off:** the L1 TCDM ports are only 858 of the 3248 wires
(26 %). The cost is dominated by the **512-bit DMA port (1131) and the tile AXI port (1245)**. If
the DMA and AXI hierarchies were kept whole on one tier (only the L1 xbars split), the per-tile
crossing falls to 858 → model A = **109 824** chip-wide, which is competitive with scheme 4.
That is the single highest-leverage refinement available in this scheme.

## 4. Scheme 3 — PE bottom, SRAM macros top

| variant | cut at | per tile | **chip** |
|---|---|---|---|
| 3a: L1 **and** L2 NoC on bottom → only macros up | SRAM bank pins, 16 × 78 | 1248 | **319 488** |
| 3b: L1 NoC **up** with the SRAM | core data ports, 5 × 122 | 610 | **156 160** |

**Moving the L1 NoC up roughly halves the pins (0.49×)** — because the bank side of the tile
crossbar (16 banks × 78 = 1248) is *wider* than the core side (5 ports × 122 = 610). The L1
crossbar is a fan-out stage; cutting on its narrow (core) side is strictly better than cutting on
its wide (bank) side. This is the clearest design guidance in the whole comparison.

Caveats to add on top of 3b, depending on where the rest lands:
- if the **L2/AXI refill path stays on the bottom** while the L1 NoC is up, each tile's AXI port
  (1245) also crosses → +318 720 chip-wide, which *reverses* the 3a/3b ranking. Keeping the
  icache-refill/AXI path on the same tier as the L1 NoC is essential for 3b to pay off.
- L2 macros stacked as well: 16 banks × (512 wdata + 512 rdata + 64 be + addr + ctrl) ≈ 17 600 —
  negligible next to L1.
- 8×8: 3a = 1 277 952, 3b = 624 640.

## 5. Scheme 4 — L1 NoC routers + mesh wiring on top

The mesh wiring becomes intra-tier (free); what crosses is every router's **local (inject/eject)
port**, for all 16 router columns × 2 channels per group:

| item | per group | **chip (16 groups)** |
|---|---|---|
| req routers 16·2·(95+95) | 6080 | 97 280 |
| resp routers 16·2·(70+70) | 4480 | 71 680 |
| **TCDM total** | **10 560** | **168 960** |
| + AXI/L2 routers & mesh also up | +1682 | 195 872 |

8×8: 11 072 × 64 = **708 608**.

Note this is *exactly 2×* one mesh-direction bundle per group — the local port carries both
directions. Cutting at the router local port is therefore always worse than cutting the mesh links
themselves (scheme 1) by roughly the ratio (2 × #groups)/(#z-links) = 32/8 = 4× here.

## 6. Comparison and ranking

Chip-wide tier-to-tier wires, 4×4 / 256-core:

| rank | scheme | pins | vs best |
|---|---|---|---|
| 1 | **1. group boundary, 3D mesh** | **97 936** | 1.0× |
| 2 | 2 with DMA+AXI kept planar (L1 xbars only) | 109 824 | 1.1× |
| 3 | 3b. PE / (L1 NoC + SRAM) | 156 160 | 1.6× |
| 4 | 4. routers + mesh up | 168 960 | 1.7× |
| 5 | 3a. PE + NoC / SRAM only | 319 488 | 3.3× |
| 6 | 2. tile boundary (model A, full tile iface) | 415 744 | 4.2× |
| 7 | 2. tile boundary (model B) | 831 488 | 8.5× |

### 6.1 Bond-area feasibility

Required bond area = pins / density; density = 10⁶/pitch² per mm² (pitch in µm).

| scheme (4×4) | 40 µm µbump (625/mm²) | 10 µm (10⁴/mm²) | 5 µm (4·10⁴) | 1 µm hybrid (10⁶) |
|---|---|---|---|---|
| 1 (97 936) | 157 mm² | 9.8 mm² | 2.4 mm² | 0.10 mm² |
| 3b (156 160) | 250 | 15.6 | 3.9 | 0.16 |
| 4 (168 960) | 270 | 16.9 | 4.2 | 0.17 |
| 3a (319 488) | 511 | 32.0 | 8.0 | 0.32 |
| 2A (415 744) | 665 | 41.6 | 10.4 | 0.42 |

Reading: **at µbump pitch (≥10 µm) only scheme 1 is comfortably feasible** for a 256-core die;
every other scheme needs hybrid bonding (≤5 µm) to keep the bond array from dominating die area.
At 1 µm hybrid bonding all schemes are area-feasible, and the choice shifts to timing/power
(a cut in the middle of a combinational L1 crossbar — schemes 2/3a — adds tier-crossing delay
inside a single-cycle path, whereas schemes 1 and 4 cut already-registered NoC links).

## 7. Caveats

- Wire counts are **RTL interface bits**, i.e. an upper bound on signal pins; they exclude power,
  ground, clock and test, which typically add 20–40 % in real 3D stacks.
- Every channel counted includes its `valid`/`ready`; the `ready` physically runs opposite to the
  data but still consumes one bond.
- Schemes 2 and 3a cut *combinational* paths (the tile/group crossbars are single-cycle), so they
  additionally cost timing; schemes 1 and 4 cut registered router links and are latency-tolerant.
- Scheme 2's two models bracket the real answer; the true number depends on how the split
  crossbars are arbitrated, which is a design choice not yet made.
