# sp-fmatmul-opt-burst-merge

Burst-optimized `float32` matrix multiply (C = A·B, α=0) for TeraNoC + Spatz.

Each core computes a tile of C with an LMUL=2 inner loop (`vsetvli e32, m2`,
**VL = 32 elements = 128 bytes** per B-row vector load). The Spatz VLSU
auto-splits each aligned 128-byte unit-stride load into **2 × 16-word
(64-byte) burst requests** on the NoC, and the per-group MSHR can coalesce the
identical B-row loads issued by sibling cores. This kernel exists to exercise
that VLSU-burst + group-MSHR-merge path under a realistic GEMM.

> **Config note.** `main.c` is fully parametric — the work split is derived at
> run time from `mempool_get_core_count()` and `NUM_GROUPS`. The numbers below
> are the **concrete instance for `terapool_spatz4_fpu`** (the only flavour that
> boots on this branch), with the matrix size shipped in `data/` (256³). Build
> with a matching `config=` or the split degenerates.

## Matrix dimensions & system config

- **M = N = P = 256** — A:256×256, B:256×256, C:256×256, all `float32`
  (from `script/matmul.json`; `data/data_*.h` is generated and git-ignored).
  α = 0, so the true result is plain A·B and `gemm_checksum` holds the true
  per-row sums (the `gemm_C_dram` array is a random accumulate-init, **not** a
  golden — do not compare against it).
- **256 cores · 16 groups · `cores_per_group` = 16** (`terapool_spatz4_fpu`,
  1 core/tile, `N_FPU` = 4).
- **`kernel_size` = 8** — 8 output rows of C per `matmul_8xVL` invocation.

## Work distribution across cores

Derived constants (`main.c` STEP 2):

```
active_groups   = NUM_GROUPS                         = 16
cores_per_group = num_cores / NUM_GROUPS             = 256 / 16 = 16
dim_group       = M / active_groups                  = 256 / 16 = 16   rows per group
split_m_count   = dim_group / kernel_size            = 16 / 8   = 2
```

Since `split_m_count (2) < cores_per_group (16)`, **both** M and P are split:

```
split_p_count   = cores_per_group / split_m_count    = 16 / 2 = 8
cols per core   = P / split_p_count                  = 256 / 8 = 32   (= 128 bytes, burst-eligible)
```

Each core gets:
- **p_start..p_end**: 32 columns, `p_start = 32 · (core_gid % 8)`
- **m_start..m_end**: 8 rows, `m_start = dim_group·gid + 8·(core_gid / 8)`

i.e. each core computes an **8×32 tile** of C. Group `gid` owns rows
`[16·gid, 16·gid + 16)`; the 16 cores in a group cover those 16 rows
(2 row-blocks of 8) × all 256 columns (8 column-strips of 32).

### Concrete core assignments (group 0, cores 0–15)

| core_gid | m_start | m_end | p_start | p_end |
|----------|---------|-------|---------|-------|
| 0        | 0       | 8     | 0       | 32    |
| 1        | 0       | 8     | 32      | 64    |
| 2        | 0       | 8     | 64      | 96    |
| 3        | 0       | 8     | 96      | 128   |
| 4        | 0       | 8     | 128     | 160   |
| 5        | 0       | 8     | 160     | 192   |
| 6        | 0       | 8     | 192     | 224   |
| 7        | 0       | 8     | 224     | 256   |
| 8        | 8       | 16    | 0       | 32    |
| 9        | 8       | 16    | 32      | 64    |
| 10       | 8       | 16    | 64      | 96    |
| 11       | 8       | 16    | 96      | 128   |
| 12       | 8       | 16    | 128     | 160   |
| 13       | 8       | 16    | 160     | 192   |
| 14       | 8       | 16    | 192     | 224   |
| 15       | 8       | 16    | 224     | 256   |

Groups 1–15 use the identical column pattern but rows `[16·gid, 16·gid+16)`.

**Coalescing structure (the point of this kernel).** Within a group the two
row-blocks share the same column-strips: core `k` and core `k+8`
(`k = 0..7`) have the **same `p_start`** and therefore load the **same B
addresses** → **2-way B coalescing per group** (8 such pairs). The 16 cores
also sweep B in lockstep over `n`, so the per-group MSHR sees repeated
same-line burst loads. (A higher coalescing degree would require fewer
column-strips, i.e. a larger per-core P-tile — see "tuning" below.)

## Inner-loop memory access pattern (`matmul_8xVL`)

For a core with `m_start=0, m_end=8, p_start=0, p_end=32` (kernel/sp-fmatmul.c):

- **p-loop**: one iteration — `vsetvli e32, m2` with `vl = p_end-p = 32`
  ⇒ `gvl = 32` covers all 32 columns.
- **m-loop**: one iteration — 8 rows.
- **n-loop**: `n = 0 .. N-1 = 255`, unrolled by 2 with a B-row ping-pong
  (`v18`/`v20`). Each `n`:

#### 1. Vector load of a B row (contiguous, burst-eligible)
```
vle32.v v18/v20, (b__)     // 32 floats = 128 bytes
b__ += P                   // next B row: stride P·4 = 1024 bytes
```
- Address: `base_B + n·P·4 + p_start·4 = base_B + n·1024 + 128·(core_gid%8)`
- Unit-stride, 64B-aligned ⇒ **burst-eligible**: auto-splits into
  **2 × 16-word (64-byte) bursts**.
- Double-buffered: `v18`/`v20` alternate so the next B row prefetches while
  the current one feeds the FPU.

#### 2. Eight scalar loads of an A column (scattered across rows)
```
t0 = A[m+0][n]   addr: base_A + 0·N·4 + n·4 = base_A + n·4
t1 = A[m+1][n]   addr: base_A + 1·N·4 + n·4 = base_A + 1024 + n·4
...
t7 = A[m+7][n]   addr: base_A + 7·N·4 + n·4 = base_A + 7168 + n·4
```
- Stride between A rows = N·4 = 1024 bytes.
- Each is a **single 4-byte scalar `flw`** via the Snitch/FP-LSU shared port 0
  (**not** the VLSU) — these never burst; they're interleaved with the FPU ops
  for latency hiding.

#### 3. Eight `vfmul`/`vfmacc` (FPU, no memory)
```
vfmacc.vf v0,  t0, v18    // C[m+0][p..p+31] += A[m+0][n] · B[n][p..p+31]
...
vfmacc.vf v14, t7, v18    // C[m+7][p..p+31] += A[m+7][n] · B[n][p..p+31]
```
The first iteration (`n=0`) uses `vfmul.vf` to initialise the 8 accumulators;
subsequent iterations accumulate with `vfmacc.vf`.

#### After the inner loop — 8 vector stores
```
vse32.v v0,  (c__)        // C[m+0][p..p+31], 128 bytes
c__ += P                  // next row: stride 1024 bytes
... 8 stores total
```

### Traffic per core (one 8×32 tile, full `n = 0..255`)

| Access        | Type           | Size      | Count | Address pattern                          |
|---------------|----------------|-----------|-------|------------------------------------------|
| B row load    | Vector (burst) | 128 B     | 256   | `base_B + n·1024 + 128·(core_gid%8)`, contiguous |
| A elem loads  | Scalar (`flw`) | 4 B       | 2 048 | `base_A + row·1024 + n·4`, stride 1024 B  |
| `vfmul/vfmacc`| FPU (no mem)   | —         | 2 048 | —                                        |
| C row stores  | Vector         | 128 B     | 8     | `base_C + row·1024 + 128·(core_gid%8)`    |

Totals per core: **256 B-loads = 32 KiB**, **2 048 A-loads = 8 KiB**,
**8 C-stores = 1 KiB**.

## Per-core starting-address differences

### B-matrix loads (vector, burst)
Cores in the same group with the same `core_gid % 8` load **identical** B
addresses (the coalescing pairs above). The 8 distinct column-strips map to
byte offsets:

| `core_gid % 8` | B byte offset added | shares with |
|----------------|---------------------|-------------|
| 0 | `+0`   | core_gid 0 & 8 |
| 1 | `+128` | 1 & 9  |
| 2 | `+256` | 2 & 10 |
| …​ | …​     | …​     |
| 7 | `+896` | 7 & 15 |

### A-matrix loads (scalar)
Cores sharing a row-block (`core_gid / 8`) read the **same** A elements:
- block 0 (core_gid 0–7):  `A[0..7][n]`,  base `base_A + n·4`
- block 1 (core_gid 8–15): `A[8..15][n]`, base `base_A + 8192 + n·4`

All 8 cores in a row-block hit identical A addresses every `n` ⇒ **high bank
contention on A** (scalar port 0).

### C-matrix stores (vector)
Each core writes a unique, non-overlapping 8×32 tile —
`base_C + row·1024 + 128·(core_gid%8)` — **no write conflicts**.

## Register allocation (`matmul_8xVL`, LMUL=2)
32 vector registers; LMUL=2 ⇒ each logical vreg spans 2 physical registers:

| Registers | Usage | Physical regs |
|-----------|-------|---------------|
| v0,v2,v4,v6,v8,v10,v12,v14 | 8 accumulators (C rows) | 16 |
| v18 | B[n] (ping)   | 2 |
| v20 | B[n+1] (pong)  | 2 |
| **Total** | | **20 / 32** |

Scalar floats `t0..t7` hold `A[m+0..7][n]`.

## Address-to-tile mapping (terapool, for NoC analysis)
TCDM is word-interleaved; for terapool the L1 byte address decomposes as:
```
bank_id  = byte_addr[5:2]    // 16 banks/tile, 4 B each  → 64 B per tile
tile_id  = byte_addr[9:6]    // 16 tiles/group           → 1024 B per group
group_id = byte_addr[13:10]  // 16 groups
row_addr = byte_addr[…:14]   // word within the bank
```
Consequences for the B burst load (`base_B + n·1024 + 128·(core_gid%8)`):
- Each **64-byte burst (16 words) stays within one tile** (64B-aligned); the
  two bursts of one 128-byte LMUL=2 load go to **two consecutive tiles**.
- Successive B rows step by `n·1024` = exactly one **group stride**, so
  consecutive `n` walk the B row across **successive groups** — most B loads
  are *remote* to the issuing core's group, which is what makes them traverse
  the NoC and become MSHR-coalescing candidates.

## Verification
Core 0 runs `verify_matrix()` (STEP 6) — the same self-test as `sp-fmatmul-opt`:
for each of the M rows it sums `c[i][0..P-1]` and compares to the precomputed
row checksum `r[i]` (= `gemm_checksum`, host-verified) with an absolute
tolerance of `0.001`. It uses only scalar locals (no per-row product buffer, so
nothing large lands on the 512-B per-core stack) and **no fp division** (this
config is `nofdiv`/`XDIVSQRT=0`; `fdiv.s` would trap). Returns `0` on success or
`failing_row + 1`. All cores reach the final barrier before returning so the sim
exits cleanly — do **not** add a core-0-only early return (it skips the barrier
and hangs the run).

## Tuning the burst / coalescing test
- **Burst eligibility** needs ≥ 64-byte (≥16-word) aligned unit-stride e32
  loads. The 32-column (128 B) B-row load gives 2 full 16-word bursts per load;
  it is already the burst design point.
- **Coalescing degree** is set by how many cores share a B column-strip. With
  256³ on 256 cores it is **2-way** per group. To raise it, increase the
  per-core P-tile (fewer column-strips) — e.g. a larger M (more rows/group →
  larger `split_m_count` → smaller `split_p_count`) or fewer active cores.
- Build/run on `terapool_spatz4_fpu`; use `GROUP_MSHR_ENABLE_STATS` +
  `tb_noc_req_resp_tracer` to observe the burst split and the merge rate
  (remember `[MSHR stats]` are **per-period, not cumulative**).
