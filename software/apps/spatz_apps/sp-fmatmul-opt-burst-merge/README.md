# sp-fmatmul-opt-burst-merge

Burst-optimized matrix multiplication kernel for TeraNoC + Spatz.

Uses LMUL=2 (`vsetvli e32, m2`, VL=32 elements = 128 bytes per vector load).
The Spatz VLSU automatically splits each aligned 128-byte load into
2 x 16-word burst requests on the NoC.

## Matrix Dimensions & System Config

- **M = N = P = 128** (A: 128x128, B: 128x128, C: 128x128, all float32)
- **64 cores**, 4 groups of 16 cores each (`cores_per_group = 16`)
- **kernel_size = 8** (8 output rows per `matmul_8xVL` invocation)

## Work Distribution Across Cores

With `dim_group = M / 4 = 32` rows per group and
`split_m_count = dim_group / kernel_size = 32 / 8 = 4`:

Since `split_m_count (4) < cores_per_group (16)`, both M and P dimensions
are split:

```
split_p_count = cores_per_group / split_m_count = 16 / 4 = 4
```

Each core gets:
- **p_start..p_end**: P/4 = 32 columns (based on `core_gid % 4`)
- **m_start..m_end**: 8 rows, one kernel_size block (based on `core_gid / 4`)
- **m_start offset**: `dim_group * gid + 8 * (core_gid / 4)`

### Concrete Core Assignments (Group 0, cores 0-15)

| core_gid | m_start | m_end | p_start | p_end |
|----------|---------|-------|---------|-------|
| 0        | 0       | 8     | 0       | 32    |
| 1        | 0       | 8     | 32      | 64    |
| 2        | 0       | 8     | 64      | 96    |
| 3        | 0       | 8     | 96      | 128   |
| 4        | 8       | 16    | 0       | 32    |
| 5        | 8       | 16    | 32      | 64    |
| 6        | 8       | 16    | 64      | 96    |
| 7        | 8       | 16    | 96      | 128   |
| 8        | 16      | 24    | 0       | 32    |
| 9        | 16      | 24    | 32      | 64    |
| 10       | 16      | 24    | 64      | 96    |
| 11       | 16      | 24    | 96      | 128   |
| 12       | 24      | 32    | 0       | 32    |
| 13       | 24      | 32    | 32      | 64    |
| 14       | 24      | 32    | 64      | 96    |
| 15       | 24      | 32    | 96      | 128   |

Groups 1-3 get rows 32-63, 64-95, 96-127 respectively (same column pattern
within each group).

## Inner Loop Memory Access Pattern (matmul_8xVL)

For a single core with `m_start=0, m_end=8, p_start=0, p_end=32`:

### Outer Loops

- **p-loop**: `p=0`, `gvl=32` (LMUL=2, VL=32 elements, 128 bytes).
  One iteration covers all 32 columns.
- **m-loop**: `m=0`, single iteration (8 rows).

### Inner Loop (n = 0..127)

Each iteration of `n` performs three phases:

#### 1. Vector Load of B Row (contiguous, burst-eligible)

```
vle32.v v18/v20, (b__)     // 32 floats = 128 bytes
b__ += P = 128             // stride between B rows = 512 bytes
```

- Address: `base_B + n * P * 4 = base_B + n * 512`  (offset by `p_start * 4`)
- Unit-stride, 128-byte aligned load — **burst-eligible**
- Auto-splits into 2 x 16-word (64-byte) burst requests on the NoC
- Double-buffered: even iterations load into v18, odd into v20

#### 2. Eight Scalar Loads of A Column (scattered across rows)

```
t0 = A[m+0][n]    addr: base_A + 0*N*4 + n*4    = base_A + n*4
t1 = A[m+1][n]    addr: base_A + 1*N*4 + n*4    = base_A + 512 + n*4
t2 = A[m+2][n]    addr: base_A + 2*N*4 + n*4    = base_A + 1024 + n*4
...
t7 = A[m+7][n]    addr: base_A + 7*N*4 + n*4    = base_A + 3584 + n*4
```

- Stride between rows = N = 128 floats = 512 bytes
- Each `flw` is a single 4-byte scalar load via Snitch's LSU (not Spatz VLSU)
- These are interleaved with the vfmul/vfmacc instructions for latency hiding

#### 3. Eight vfmul/vfmacc Operations (FPU, no memory access)

```
vfmacc.vf v0,  t0, v18    // C[m+0][p..p+31] += A[m+0][n] * B[n][p..p+31]
vfmacc.vf v2,  t1, v18    // C[m+1][p..p+31] += A[m+1][n] * B[n][p..p+31]
vfmacc.vf v4,  t2, v18    // C[m+2][p..p+31] += A[m+2][n] * B[n][p..p+31]
...
vfmacc.vf v14, t7, v18    // C[m+7][p..p+31] += A[m+7][n] * B[n][p..p+31]
```

First iteration (n=0) uses `vfmul.vf` to initialize accumulators; subsequent
iterations use `vfmacc.vf` to accumulate.

### After Inner Loop (Stores)

```
vse32.v v0,  (c__)         // Store C[m+0][p..p+31], 128 bytes
c__ += P                   // Next row: stride 512 bytes
vse32.v v2,  (c__)         // Store C[m+1][p..p+31]
...                        // 8 stores total
```

### Traffic Summary Per Inner-Loop Iteration

| Access          | Type             | Size      | Count/iter | Address pattern                     |
|-----------------|------------------|-----------|------------|-------------------------------------|
| B column load   | Vector (burst)   | 128 bytes | 1          | `base_B + n*512 + p_start*4`, contiguous |
| A element loads | Scalar (flw)     | 4B each   | 8          | `base_A + row*512 + n*4`, stride-512B    |
| vfmul/vfmacc    | FPU (no mem)     | --        | 8          | --                                  |

Over the full inner loop (128 iterations): **128 vector B-loads** (16,384 bytes
per core) + **1,024 scalar A-loads** (4,096 bytes per core).

## Per-Core Starting Address Differences

Using `mempool_spatz4_fpu` config (64 cores, 4 groups, bank-interleaved L1
TCDM):

### B-matrix Loads (vector, burst)

All cores in the same p-column group load from the **same B rows** but at
different column offsets:

- Core with `p_start=0`:  loads from `base_B + n*512 + 0`
- Core with `p_start=32`: loads from `base_B + n*512 + 128`
- Core with `p_start=64`: loads from `base_B + n*512 + 256`
- Core with `p_start=96`: loads from `base_B + n*512 + 384`

The 128-byte offset between p-columns means **different tile IDs** in the
bank-interleaving scheme (each tile owns 64 bytes = 16 banks x 4B). Cores with
different `p_start` values access different tiles for B.

### A-matrix Loads (scalar)

Cores in the same m-row group read the **same A elements**:

- All 4 cores with `m_start=0` read `A[0..7][n]` for every `n`
- These are identical addresses — **high bank contention on A**

Cores in different m-row groups read different A rows:

- `m_start=0`:  `A[0..7][n]`,  base = `base_A + n*4`
- `m_start=8`:  `A[8..15][n]`, base = `base_A + 4096 + n*4`
- `m_start=16`: `A[16..23][n]`, base = `base_A + 8192 + n*4`
- `m_start=24`: `A[24..31][n]`, base = `base_A + 12288 + n*4`

### C-matrix Stores (vector)

Each core writes a unique, non-overlapping tile of C:

- Core `(m=0, p=0)`:   `C[0..7][0..31]`   at `base_C + m*512 + p*4`
- Core `(m=0, p=32)`:  `C[0..7][32..63]`   at `base_C + m*512 + 128`
- Core `(m=0, p=64)`:  `C[0..7][64..95]`   at `base_C + m*512 + 256`
- Core `(m=0, p=96)`:  `C[0..7][96..127]`  at `base_C + m*512 + 384`

No write conflicts between cores.

## Register Allocation (matmul_8xVL, LMUL=2)

32 vector registers, LMUL=2 means each "vreg" spans 2 physical registers:

| Registers  | Usage                           | Regs used |
|------------|---------------------------------|-----------|
| v0, v2, v4, v6, v8, v10, v12, v14 | 8 accumulators (C rows) | 16 |
| v18        | B[n] column vector (ping)       | 2         |
| v20        | B[n+1] column vector (pong)     | 2         |
| **Total**  |                                 | **20/32** |

Scalar floats t0..t7 hold `A[m+0..7][n]` elements.

## Address-to-Tile Mapping (for NoC analysis)

With the mempool bank-interleaving scheme:

```
byte_addr  = base + offset
bank_id    = byte_addr[5:2]         // 16 banks per tile, 4B each
tile_id    = byte_addr[9:6]         // 16 tiles per group
group_id   = byte_addr[11:10]       // 4 groups
bank_addr  = byte_addr[...12+]      // address within the bank
```

For B-matrix burst loads at `base_B + n*512 + p_start*4`:

- `p_start=0`:  byte offset 0   -> tile_id from bits [9:6] of base_B
- `p_start=32`: byte offset 128 -> tile_id shifts by 128/64 = 2 tiles
- `p_start=64`: byte offset 256 -> tile_id shifts by 4 tiles
- `p_start=96`: byte offset 384 -> tile_id shifts by 6 tiles

Each burst of 64 bytes (16 words) stays within a single tile (aligned to 64B).
The two 16-word bursts within a 128B LMUL=2 load go to **two consecutive
tiles**.
