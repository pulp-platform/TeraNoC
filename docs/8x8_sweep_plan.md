# 8x8 scale-up sweep — feasible shapes, configuration, and plan

**Status:** draft for review, nothing dispatched. Written 2026-08-22.

**Goal.** Run the main-tree design (idea-2 + bank-full backpressure + the
`cache_reuse_target` bit-width fix) on the **8x8 mesh** (1024 cores, 64 groups) to
measure how the MSHR coalescing design scales, against the 4x4 (256 core, 16 group)
data collected on 2026-08-21/22.

> Scope note: this plan targets the **main tree** `sp-fp16-*` / `sp-fp32-*` apps.
> The packed-A kernel lives on `worktree-fp16-packed-a` and is NOT part of it.

---

## 1. What limits a shape at 8x8

Three independent gates. All are checked here; none is guessed.

### 1a. Legality — `main.c`'s own guards

| guard | rule | source |
|---|---|---|
| `-3` | `N % 2 == 0` | inner loop unrolls `n` by 2 |
| `-4` | `M % 64 == 0` | M rows split across `active_groups = NUM_GROUPS = 64` |
| `-6` | `(M/64) % kernel_size == 0`, `> 0` | `dim_group` must cover whole kernel tiles |
| `-5` | `P % split_p == 0` | P columns split per core |

With the default `kernel_size = 8`, guards `-4` and `-6` collapse to **`M % 512 == 0`**.

`split_p` — how many cores share the same A rows, i.e. the **A-share degree the group
MSHR can coalesce** — follows from M alone:

| M | `split_m` | `split_p` | P must satisfy |
|---|---|---|---|
| 512 | 1 | **16** | `P % 16 == 0` |
| 1024 | 2 | **8** | `P % 8 == 0` |
| 2048 | 4 | **4** | `P % 4 == 0` |
| 4096 | 8 | **2** | `P % 2 == 0` |
| >=8192 | 16 | **1** | any (each core takes all columns) |

### 1b. L1 capacity

`a[M*N]`, `b[N*P]`, `c[M*P]`, `r[M]` live in `.l1_prio`, each 4096-aligned.

```
L1_FULL   = NUM_CORES * N_FU * BANKING_FACTOR * L1_BANK_SIZE = 1024*4*4*1024 = 16.00 MiB
WORD_STRIDE = 4 * BANKS_PER_TILE * TILES_PER_GROUP * NUM_GROUPS = 4*16*16*64 = 65536
L1_USABLE = min(GROUP_BARRIER_WORD * WORD_STRIDE, L1_FULL) = min(15.00, 16.00) = 15.00 MiB
budget    = L1_USABLE - NUM_CORES*SEQ_MEM_SIZE = 15.00 - 0.50 = 14.50 MiB
```

(4x4 for comparison: `WORD_STRIDE` 16384, budget 3.50 MiB — 8x8 has exactly 4x the L1.)

### 1c. Simulation wall-clock — **the binding constraint in practice**

Least-squares fit over 8 completed 4x4 VCS arms: `wall_s ~= 3691 + cycles/51.7`.
Scaled x4 for the larger design: **~2 h fixed + ~13 cyc/s at 8x8**.

Estimated cycles assume 45% of peak (`M*N*P / peak`, peak = 8192 MAC/cyc fp16,
4096 fp32 at 1024 cores). **These are order-of-magnitude only** — the fit is loose
(one arm sits 2x off the model, most likely node contention).

---

## 2. Precision: what fp16 actually buys

| | fp32 | fp16 |
|---|---|---|
| bytes/element | 4 | 2 -> **2x the elements fit** |
| peak MAC/cyc @1024 cores | 4096 | 8192 -> **same shape costs half the cycles** |
| runnable shapes on the grid below | 72 | **94** |

fp16 buys headroom in memory **and** in simulation time. It does **not** unlock
different shapes: the legality rules are precision-independent, so fp16 reaches
*bigger* sizes, never *other* ones.

The sharpest consequence: at the 1-way A-share rung the C matrix (`M*P`) dominates,
and fp32 cannot fit it at all. **The no-sharing regime is reachable only at fp16.**


### fp16 — 138 runnable shapes

**M=512 · 16-way A-share** — 35 shapes

| shape | L1 MiB | %% budget | est cycles | est h/arm |
|---|---|---|---|---|
| `512x32x128` | 0.17 | 1% | 568 | 2.1 |
| `512x32x256` | 0.30 | 2% | 1,137 | 2.1 |
| `512x64x128` | 0.21 | 1% | 1,137 | 2.1 |
| `512x32x512` | 0.57 | 4% | 2,275 | 2.1 |
| `512x64x256` | 0.35 | 2% | 2,275 | 2.1 |
| `512x128x128` | 0.29 | 2% | 2,275 | 2.1 |
| `512x32x1024` | 1.10 | 8% | 4,551 | 2.1 |
| `512x64x512` | 0.63 | 4% | 4,551 | 2.1 |
| `512x128x256` | 0.44 | 3% | 4,551 | 2.1 |
| `512x256x128` | 0.44 | 3% | 4,551 | 2.1 |
| `512x32x2048` | 2.16 | 15% | 9,102 | 2.2 |
| `512x64x1024` | 1.19 | 8% | 9,102 | 2.2 |
| `512x128x512` | 0.75 | 5% | 9,102 | 2.2 |
| `512x256x256` | 0.63 | 4% | 9,102 | 2.2 |
| `512x512x128` | 0.75 | 5% | 9,102 | 2.2 |
| `512x64x2048` | 2.32 | 16% | 18,204 | 2.4 |
| `512x128x1024` | 1.38 | 10% | 18,204 | 2.4 |
| `512x256x512` | 1.00 | 7% | 18,204 | 2.4 |
| `512x512x256` | 1.00 | 7% | 18,204 | 2.4 |
| `512x1024x128` | 1.38 | 10% | 18,204 | 2.4 |
| `512x128x2048` | 2.63 | 18% | 36,408 | 2.8 |
| `512x256x1024` | 1.75 | 12% | 36,408 | 2.8 |
| `512x512x512` | 1.50 | 10% | 36,408 | 2.8 |
| `512x1024x256` | 1.75 | 12% | 36,408 | 2.8 |
| `512x2048x128` | 2.63 | 18% | 36,408 | 2.8 |
| `512x256x2048` | 3.25 | 22% | 72,817 | 3.6 |
| `512x512x1024` | 2.50 | 17% | 72,817 | 3.6 |
| `512x1024x512` | 2.50 | 17% | 72,817 | 3.6 |
| `512x2048x256` | 3.25 | 22% | 72,817 | 3.6 |
| `512x512x2048` | 4.50 | 31% | 145,635 | 5.2 |
| `512x1024x1024` | 4.00 | 28% | 145,635 | 5.2 |
| `512x2048x512` | 4.50 | 31% | 145,635 | 5.2 |
| `512x1024x2048` | 7.00 | 48% | 291,271 | 8.3 |
| `512x2048x1024` | 7.00 | 48% | 291,271 | 8.3 |
| `512x2048x2048` | 12.00 | 83% | 582,542 | 14.6 |

**M=1024 · 8-way** — 34 shapes

| shape | L1 MiB | %% budget | est cycles | est h/arm |
|---|---|---|---|---|
| `1024x32x128` | 0.32 | 2% | 1,137 | 2.1 |
| `1024x32x256` | 0.58 | 4% | 2,275 | 2.1 |
| `1024x64x128` | 0.39 | 3% | 2,275 | 2.1 |
| `1024x32x512` | 1.10 | 8% | 4,551 | 2.1 |
| `1024x64x256` | 0.66 | 5% | 4,551 | 2.1 |
| `1024x128x128` | 0.54 | 4% | 4,551 | 2.1 |
| `1024x32x1024` | 2.13 | 15% | 9,102 | 2.2 |
| `1024x64x512` | 1.19 | 8% | 9,102 | 2.2 |
| `1024x128x256` | 0.82 | 6% | 9,102 | 2.2 |
| `1024x256x128` | 0.82 | 6% | 9,102 | 2.2 |
| `1024x32x2048` | 4.19 | 29% | 18,204 | 2.4 |
| `1024x64x1024` | 2.25 | 16% | 18,204 | 2.4 |
| `1024x128x512` | 1.38 | 10% | 18,204 | 2.4 |
| `1024x256x256` | 1.13 | 8% | 18,204 | 2.4 |
| `1024x512x128` | 1.38 | 10% | 18,204 | 2.4 |
| `1024x64x2048` | 4.38 | 30% | 36,408 | 2.8 |
| `1024x128x1024` | 2.50 | 17% | 36,408 | 2.8 |
| `1024x256x512` | 1.75 | 12% | 36,408 | 2.8 |
| `1024x512x256` | 1.75 | 12% | 36,408 | 2.8 |
| `1024x1024x128` | 2.50 | 17% | 36,408 | 2.8 |
| `1024x128x2048` | 4.75 | 33% | 72,817 | 3.6 |
| `1024x256x1024` | 3.00 | 21% | 72,817 | 3.6 |
| `1024x512x512` | 2.50 | 17% | 72,817 | 3.6 |
| `1024x1024x256` | 3.00 | 21% | 72,817 | 3.6 |
| `1024x2048x128` | 4.75 | 33% | 72,817 | 3.6 |
| `1024x256x2048` | 5.50 | 38% | 145,635 | 5.2 |
| `1024x512x1024` | 4.00 | 28% | 145,635 | 5.2 |
| `1024x1024x512` | 4.00 | 28% | 145,635 | 5.2 |
| `1024x2048x256` | 5.50 | 38% | 145,635 | 5.2 |
| `1024x512x2048` | 7.00 | 48% | 291,271 | 8.3 |
| `1024x1024x1024` | 6.00 | 41% | 291,271 | 8.3 |
| `1024x2048x512` | 7.00 | 48% | 291,271 | 8.3 |
| `1024x1024x2048` | 10.00 | 69% | 582,542 | 14.6 |
| `1024x2048x1024` | 10.00 | 69% | 582,542 | 14.6 |

**M=2048 · 4-way** — 32 shapes

| shape | L1 MiB | %% budget | est cycles | est h/arm |
|---|---|---|---|---|
| `2048x32x128` | 0.64 | 4% | 2,275 | 2.1 |
| `2048x32x256` | 1.14 | 8% | 4,551 | 2.1 |
| `2048x64x128` | 0.77 | 5% | 4,551 | 2.1 |
| `2048x32x512` | 2.16 | 15% | 9,102 | 2.2 |
| `2048x64x256` | 1.29 | 9% | 9,102 | 2.2 |
| `2048x128x128` | 1.04 | 7% | 9,102 | 2.2 |
| `2048x32x1024` | 4.19 | 29% | 18,204 | 2.4 |
| `2048x64x512` | 2.32 | 16% | 18,204 | 2.4 |
| `2048x128x256` | 1.57 | 11% | 18,204 | 2.4 |
| `2048x256x128` | 1.57 | 11% | 18,204 | 2.4 |
| `2048x32x2048` | 8.25 | 57% | 36,408 | 2.8 |
| `2048x64x1024` | 4.38 | 30% | 36,408 | 2.8 |
| `2048x128x512` | 2.63 | 18% | 36,408 | 2.8 |
| `2048x256x256` | 2.13 | 15% | 36,408 | 2.8 |
| `2048x512x128` | 2.63 | 18% | 36,408 | 2.8 |
| `2048x64x2048` | 8.50 | 59% | 72,817 | 3.6 |
| `2048x128x1024` | 4.75 | 33% | 72,817 | 3.6 |
| `2048x256x512` | 3.25 | 22% | 72,817 | 3.6 |
| `2048x512x256` | 3.25 | 22% | 72,817 | 3.6 |
| `2048x1024x128` | 4.75 | 33% | 72,817 | 3.6 |
| `2048x128x2048` | 9.00 | 62% | 145,635 | 5.2 |
| `2048x256x1024` | 5.50 | 38% | 145,635 | 5.2 |
| `2048x512x512` | 4.50 | 31% | 145,635 | 5.2 |
| `2048x1024x256` | 5.50 | 38% | 145,635 | 5.2 |
| `2048x2048x128` | 9.00 | 62% | 145,635 | 5.2 |
| `2048x256x2048` | 10.00 | 69% | 291,271 | 8.3 |
| `2048x512x1024` | 7.00 | 48% | 291,271 | 8.3 |
| `2048x1024x512` | 7.00 | 48% | 291,271 | 8.3 |
| `2048x2048x256` | 10.00 | 69% | 291,271 | 8.3 |
| `2048x512x2048` | 12.00 | 83% | 582,542 | 14.6 |
| `2048x1024x1024` | 10.00 | 69% | 582,542 | 14.6 |
| `2048x2048x512` | 12.00 | 83% | 582,542 | 14.6 |

**M=4096 · 2-way** — 23 shapes

| shape | L1 MiB | %% budget | est cycles | est h/arm |
|---|---|---|---|---|
| `4096x32x128` | 1.27 | 9% | 4,551 | 2.1 |
| `4096x32x256` | 2.27 | 16% | 9,102 | 2.2 |
| `4096x64x128` | 1.52 | 11% | 9,102 | 2.2 |
| `4096x32x512` | 4.29 | 30% | 18,204 | 2.4 |
| `4096x64x256` | 2.54 | 18% | 18,204 | 2.4 |
| `4096x128x128` | 2.04 | 14% | 18,204 | 2.4 |
| `4096x32x1024` | 8.32 | 57% | 36,408 | 2.8 |
| `4096x64x512` | 4.57 | 32% | 36,408 | 2.8 |
| `4096x128x256` | 3.07 | 21% | 36,408 | 2.8 |
| `4096x256x128` | 3.07 | 21% | 36,408 | 2.8 |
| `4096x64x1024` | 8.63 | 60% | 72,817 | 3.6 |
| `4096x128x512` | 5.13 | 35% | 72,817 | 3.6 |
| `4096x256x256` | 4.13 | 29% | 72,817 | 3.6 |
| `4096x512x128` | 5.13 | 35% | 72,817 | 3.6 |
| `4096x128x1024` | 9.26 | 64% | 145,635 | 5.2 |
| `4096x256x512` | 6.26 | 43% | 145,635 | 5.2 |
| `4096x512x256` | 6.26 | 43% | 145,635 | 5.2 |
| `4096x1024x128` | 9.26 | 64% | 145,635 | 5.2 |
| `4096x256x1024` | 10.51 | 72% | 291,271 | 8.3 |
| `4096x512x512` | 8.51 | 59% | 291,271 | 8.3 |
| `4096x1024x256` | 10.51 | 72% | 291,271 | 8.3 |
| `4096x512x1024` | 13.01 | 90% | 582,542 | 14.6 |
| `4096x1024x512` | 13.01 | 90% | 582,542 | 14.6 |

**M>=8192 · 1-way (no A sharing)** — 14 shapes

| shape | L1 MiB | %% budget | est cycles | est h/arm |
|---|---|---|---|---|
| `8192x32x128` | 2.52 | 17% | 9,102 | 2.2 |
| `8192x32x256` | 4.53 | 31% | 18,204 | 2.4 |
| `8192x64x128` | 3.03 | 21% | 18,204 | 2.4 |
| `8192x32x512` | 8.55 | 59% | 36,408 | 2.8 |
| `8192x64x256` | 5.05 | 35% | 36,408 | 2.8 |
| `8192x128x128` | 4.05 | 28% | 36,408 | 2.8 |
| `8192x64x512` | 9.08 | 63% | 72,817 | 3.6 |
| `8192x128x256` | 6.08 | 42% | 72,817 | 3.6 |
| `8192x256x128` | 6.08 | 42% | 72,817 | 3.6 |
| `8192x128x512` | 10.14 | 70% | 145,635 | 5.2 |
| `8192x256x256` | 8.14 | 56% | 145,635 | 5.2 |
| `8192x512x128` | 10.14 | 70% | 145,635 | 5.2 |
| `8192x256x512` | 12.27 | 85% | 291,271 | 8.3 |
| `8192x512x256` | 12.27 | 85% | 291,271 | 8.3 |


### fp32 — 110 runnable shapes

**M=512 · 16-way A-share** — 34 shapes

| shape | L1 MiB | %% budget | est cycles | est h/arm |
|---|---|---|---|---|
| `512x32x128` | 0.33 | 2% | 1,137 | 2.1 |
| `512x32x256` | 0.60 | 4% | 2,275 | 2.1 |
| `512x64x128` | 0.41 | 3% | 2,275 | 2.1 |
| `512x32x512` | 1.13 | 8% | 4,551 | 2.1 |
| `512x64x256` | 0.69 | 5% | 4,551 | 2.1 |
| `512x128x128` | 0.57 | 4% | 4,551 | 2.1 |
| `512x32x1024` | 2.19 | 15% | 9,102 | 2.2 |
| `512x64x512` | 1.25 | 9% | 9,102 | 2.2 |
| `512x128x256` | 0.88 | 6% | 9,102 | 2.2 |
| `512x256x128` | 0.88 | 6% | 9,102 | 2.2 |
| `512x32x2048` | 4.32 | 30% | 18,204 | 2.4 |
| `512x64x1024` | 2.38 | 16% | 18,204 | 2.4 |
| `512x128x512` | 1.50 | 10% | 18,204 | 2.4 |
| `512x256x256` | 1.25 | 9% | 18,204 | 2.4 |
| `512x512x128` | 1.50 | 10% | 18,204 | 2.4 |
| `512x64x2048` | 4.63 | 32% | 36,408 | 2.8 |
| `512x128x1024` | 2.75 | 19% | 36,408 | 2.8 |
| `512x256x512` | 2.00 | 14% | 36,408 | 2.8 |
| `512x512x256` | 2.00 | 14% | 36,408 | 2.8 |
| `512x1024x128` | 2.75 | 19% | 36,408 | 2.8 |
| `512x128x2048` | 5.25 | 36% | 72,817 | 3.6 |
| `512x256x1024` | 3.50 | 24% | 72,817 | 3.6 |
| `512x512x512` | 3.00 | 21% | 72,817 | 3.6 |
| `512x1024x256` | 3.50 | 24% | 72,817 | 3.6 |
| `512x2048x128` | 5.25 | 36% | 72,817 | 3.6 |
| `512x256x2048` | 6.50 | 45% | 145,635 | 5.2 |
| `512x512x1024` | 5.00 | 35% | 145,635 | 5.2 |
| `512x1024x512` | 5.00 | 35% | 145,635 | 5.2 |
| `512x2048x256` | 6.50 | 45% | 145,635 | 5.2 |
| `512x512x2048` | 9.00 | 62% | 291,271 | 8.3 |
| `512x1024x1024` | 8.00 | 55% | 291,271 | 8.3 |
| `512x2048x512` | 9.00 | 62% | 291,271 | 8.3 |
| `512x1024x2048` | 14.00 | 97% | 582,542 | 14.6 |
| `512x2048x1024` | 14.00 | 97% | 582,542 | 14.6 |

**M=1024 · 8-way** — 32 shapes

| shape | L1 MiB | %% budget | est cycles | est h/arm |
|---|---|---|---|---|
| `1024x32x128` | 0.64 | 4% | 2,275 | 2.1 |
| `1024x32x256` | 1.16 | 8% | 4,551 | 2.1 |
| `1024x64x128` | 0.79 | 5% | 4,551 | 2.1 |
| `1024x32x512` | 2.19 | 15% | 9,102 | 2.2 |
| `1024x64x256` | 1.32 | 9% | 9,102 | 2.2 |
| `1024x128x128` | 1.07 | 7% | 9,102 | 2.2 |
| `1024x32x1024` | 4.25 | 29% | 18,204 | 2.4 |
| `1024x64x512` | 2.38 | 16% | 18,204 | 2.4 |
| `1024x128x256` | 1.63 | 11% | 18,204 | 2.4 |
| `1024x256x128` | 1.63 | 11% | 18,204 | 2.4 |
| `1024x32x2048` | 8.38 | 58% | 36,408 | 2.8 |
| `1024x64x1024` | 4.50 | 31% | 36,408 | 2.8 |
| `1024x128x512` | 2.75 | 19% | 36,408 | 2.8 |
| `1024x256x256` | 2.25 | 16% | 36,408 | 2.8 |
| `1024x512x128` | 2.75 | 19% | 36,408 | 2.8 |
| `1024x64x2048` | 8.75 | 60% | 72,817 | 3.6 |
| `1024x128x1024` | 5.00 | 35% | 72,817 | 3.6 |
| `1024x256x512` | 3.50 | 24% | 72,817 | 3.6 |
| `1024x512x256` | 3.50 | 24% | 72,817 | 3.6 |
| `1024x1024x128` | 5.00 | 35% | 72,817 | 3.6 |
| `1024x128x2048` | 9.50 | 66% | 145,635 | 5.2 |
| `1024x256x1024` | 6.00 | 41% | 145,635 | 5.2 |
| `1024x512x512` | 5.00 | 35% | 145,635 | 5.2 |
| `1024x1024x256` | 6.00 | 41% | 145,635 | 5.2 |
| `1024x2048x128` | 9.50 | 66% | 145,635 | 5.2 |
| `1024x256x2048` | 11.00 | 76% | 291,271 | 8.3 |
| `1024x512x1024` | 8.00 | 55% | 291,271 | 8.3 |
| `1024x1024x512` | 8.00 | 55% | 291,271 | 8.3 |
| `1024x2048x256` | 11.00 | 76% | 291,271 | 8.3 |
| `1024x512x2048` | 14.00 | 97% | 582,542 | 14.6 |
| `1024x1024x1024` | 12.00 | 83% | 582,542 | 14.6 |
| `1024x2048x512` | 14.00 | 97% | 582,542 | 14.6 |

**M=2048 · 4-way** — 23 shapes

| shape | L1 MiB | %% budget | est cycles | est h/arm |
|---|---|---|---|---|
| `2048x32x128` | 1.27 | 9% | 4,551 | 2.1 |
| `2048x32x256` | 2.29 | 16% | 9,102 | 2.2 |
| `2048x64x128` | 1.54 | 11% | 9,102 | 2.2 |
| `2048x32x512` | 4.32 | 30% | 18,204 | 2.4 |
| `2048x64x256` | 2.57 | 18% | 18,204 | 2.4 |
| `2048x128x128` | 2.07 | 14% | 18,204 | 2.4 |
| `2048x32x1024` | 8.38 | 58% | 36,408 | 2.8 |
| `2048x64x512` | 4.63 | 32% | 36,408 | 2.8 |
| `2048x128x256` | 3.13 | 22% | 36,408 | 2.8 |
| `2048x256x128` | 3.13 | 22% | 36,408 | 2.8 |
| `2048x64x1024` | 8.76 | 60% | 72,817 | 3.6 |
| `2048x128x512` | 5.26 | 36% | 72,817 | 3.6 |
| `2048x256x256` | 4.26 | 29% | 72,817 | 3.6 |
| `2048x512x128` | 5.26 | 36% | 72,817 | 3.6 |
| `2048x128x1024` | 9.51 | 66% | 145,635 | 5.2 |
| `2048x256x512` | 6.51 | 45% | 145,635 | 5.2 |
| `2048x512x256` | 6.51 | 45% | 145,635 | 5.2 |
| `2048x1024x128` | 9.51 | 66% | 145,635 | 5.2 |
| `2048x256x1024` | 11.01 | 76% | 291,271 | 8.3 |
| `2048x512x512` | 9.01 | 62% | 291,271 | 8.3 |
| `2048x1024x256` | 11.01 | 76% | 291,271 | 8.3 |
| `2048x512x1024` | 14.01 | 97% | 582,542 | 14.6 |
| `2048x1024x512` | 14.01 | 97% | 582,542 | 14.6 |

**M=4096 · 2-way** — 14 shapes

| shape | L1 MiB | %% budget | est cycles | est h/arm |
|---|---|---|---|---|
| `4096x32x128` | 2.53 | 17% | 9,102 | 2.2 |
| `4096x32x256` | 4.55 | 31% | 18,204 | 2.4 |
| `4096x64x128` | 3.05 | 21% | 18,204 | 2.4 |
| `4096x32x512` | 8.58 | 59% | 36,408 | 2.8 |
| `4096x64x256` | 5.08 | 35% | 36,408 | 2.8 |
| `4096x128x128` | 4.08 | 28% | 36,408 | 2.8 |
| `4096x64x512` | 9.14 | 63% | 72,817 | 3.6 |
| `4096x128x256` | 6.14 | 42% | 72,817 | 3.6 |
| `4096x256x128` | 6.14 | 42% | 72,817 | 3.6 |
| `4096x128x512` | 10.27 | 71% | 145,635 | 5.2 |
| `4096x256x256` | 8.27 | 57% | 145,635 | 5.2 |
| `4096x512x128` | 10.27 | 71% | 145,635 | 5.2 |
| `4096x256x512` | 12.52 | 86% | 291,271 | 8.3 |
| `4096x512x256` | 12.52 | 86% | 291,271 | 8.3 |

**M>=8192 · 1-way (no A sharing)** — 7 shapes

| shape | L1 MiB | %% budget | est cycles | est h/arm |
|---|---|---|---|---|
| `8192x32x128` | 5.05 | 35% | 18,204 | 2.4 |
| `8192x32x256` | 9.06 | 62% | 36,408 | 2.8 |
| `8192x64x128` | 6.06 | 42% | 36,408 | 2.8 |
| `8192x64x256` | 10.09 | 70% | 72,817 | 3.6 |
| `8192x128x128` | 8.09 | 56% | 72,817 | 3.6 |
| `8192x128x256` | 12.16 | 84% | 145,635 | 5.2 |
| `8192x256x128` | 12.16 | 84% | 145,635 | 5.2 |


---

## 4. Hardware configuration — FOR REVIEW

### 4a. No 8x8 image exists yet

`hardware/build_vcs`, `build_vcs_fix`, `build_vcs_reuse32` are **all 4x4**. An 8x8 VCS
image must be built before anything can run.

### 4b. Three things block that build — all confirmed, none cosmetic

**(i) `config/floo_noc_terapool_spatz4_fpu_8x8.yml` does not exist.**
`hardware/Makefile:654` passes `FLOO_CFG=./config/floo_noc_$(config).yml`, so
`update-floogen` will die with `No rule to make target`. Generate it first:

```sh
python3 hardware/scripts/gen_perimeter_map.py --num-x 8 --num-y 8 \
        -o /tmp/floo8x8_scratch \
        --emit-yml config/floo_noc_terapool_spatz4_fpu_8x8.yml
```

**(ii) `hardware/generated/` currently holds a 4x4 mesh** (`NumMeshX = NumMeshY = 4`)
and is **shared by every build directory**. Building 8x8 rewrites it. Back up all three
files and restore under a `trap`, and check no other build is mid-`vlog`
(`pgrep -alf vlog`). Already-elaborated sims are safe — they read these at elaboration
only — but any *new 4x4 build* started during the 8x8 window would silently get the
wrong mesh. With ~15 fleet arms and 2 GUI runs live, do this when the tree is quiet.

**(iii) `config/terapool_spatz4_fpu_8x8.mk` was missing seven MSHR knobs — FIXED 2026-08-22.**

A knob absent from the flavour file falls back to the RTL `` `ifdef `` default, which is invisible
in the config. **Four of the seven defaults were the opposite of the 4x4 value**, so an 8x8 build
would have differed from every 4x4 arm in four MSHR behaviours at once — silently.

| knob | RTL default | 4x4 | was silently wrong at 8x8? |
|---|---|---|---|
| `group_mshr_bankfull_backpressure` | `0` | `1` | **YES** — bp OFF in HW *and* SW (`runtime.mk:154` keys the CSR write off the same variable) |
| `group_mshr_bank_publish` | `1'b0` | `1` | **YES** — publish OFF |
| `group_mshr_drain_from_q` | `1'b0` | `1` | **YES** — drain-from-q OFF |
| `group_mshr_spill_req_in` | `1'b1` | `0` | **YES** — spill ON (deadlock-relevant path) |
| `group_mshr_resp_cache` | `1'b1` | `1` | no |
| `group_mshr_cache_reuse_target` | `0` | `0` | no |
| `group_mshr_cache_timeout` | `0` | `0` | no |

All seven are now set **explicitly** in the 8x8 flavour, with the parity table reproduced in the
file itself. Verified: both flavours now define **35** `group_mshr_*` knobs with **zero** absences
and **zero** value mismatches.

Nothing here is a tuning choice — it is parity, so that an 8x8-vs-4x4 delta measures the mesh
rather than five coincidental MSHR differences.

**Parity check to re-run after any config edit:**

```sh
ex(){ grep -oE "^group_mshr_[a-z_]* +\?=[^#]*" "$1" | sed 's/ *?= */=/;s/ *$//' | sort; }
diff <(ex config/terapool_spatz4_fpu.mk) <(ex config/terapool_spatz4_fpu_8x8.mk)   # expect empty
```

The `cache_reuse_target` bit-width fix needs nothing: `MshrCfgSubsW` lives in
`mempool_pkg.sv` and is mesh-independent.

### 4b-bis. Standing convention: `group_mshr_merge_reqs = 16` in simulation

Same as every 4x4 arm. It is elaboration-only for the hardware (software sets the
actual merge target through the CSR at runtime), so it is not a tuning knob here — it
is the fixed sim setting that makes 8x8 arms comparable to the 4x4 data.

**It must be passed to the software build as well, not just the RTL build.**
`software/runtime/runtime.mk:157` reads:

```make
DEFINES += -DMSHR_MERGE_REQS=$(if $(group_mshr_merge_reqs),$(group_mshr_merge_reqs),4)
```

so an ELF built without the knob gets `MSHR_MERGE_REQS=4`. That value feeds the
`cache_reuse_target` clamp in `software/runtime/mshr_cfg.h:354`:

```c
: (MSHR_D_CACHE_REUSE_RAW > 2 * (int)MSHR_MERGE_REQS) ? 0
```

With 4 the clamp becomes `RAW > 8 -> 0`, which **silently zeroes the reuse target** on
any shape whose derived value exceeds 8 — the exact failure the bit-width fix was made
to remove, arriving by a different route. Every ELF build in section 5 therefore carries
`group_mshr_merge_reqs=16`.

### 4c. Build recipe (once i-iii are done)

```sh
cd hardware
cp -a generated /tmp/generated_4x4_backup            # and restore via trap
make -o update-floogen compile_vcs_simvopt \
     config=terapool_spatz4_fpu_8x8 \
     buildpath=build_vcs_8x8 \
     group_mshr_merge_reqs=16 \
     group_mshr_bankfull_backpressure=1
# gate before use:
grep -c '+define+GROUP_MSHR_BANKFULL_BACKPRESSURE=1' build_vcs_8x8/compilevcs.sh   # expect 1
grep -m1 NumMeshX generated/perimeter_map_pkg.sv                                    # expect 8
```

---

## 5. Software configuration — FOR REVIEW

```
tree    : main repo (NOT worktree-fp16-packed-a)
apps    : sp-fp16-<M>x<N>x<P> / sp-fp32-<M>x<N>x<P>, one per shape
generate: scripts/gen_gemm_shape_app.sh M N P [16|32]
config  : terapool_spatz4_fpu_8x8
knobs   : group_mshr_merge_reqs=16          <- REQUIRED, see 4b-bis
defines : EXTRA_DEFINES="-DMATMUL_SPOTCHECK=1"
```

Per-shape build:

```sh
rm -f software/bin/apps/spatz_apps/sp-<prec>-<M>x<N>x<P>
make -C software/apps/spatz_apps sp-<prec>-<M>x<N>x<P> \
     config=terapool_spatz4_fpu_8x8 \
     group_mshr_merge_reqs=16 \
     EXTRA_DEFINES="-DMATMUL_SPOTCHECK=1"
cp software/bin/apps/spatz_apps/sp-<prec>-<M>x<N>x<P> hardware/s8_<prec>_<M>x<N>x<P>.elf
```

Pass **no** `-DGROUP_BARRIER` and **no** `-DGBAR_PLOOP`: the kernel defaults are already
`GROUP_BARRIER=0` (per-step barrier, measured net-negative in the 2026-07-16 ablation)
and `GBAR_PLOOP=1` (per-column-block group barrier, kept). Passing neither is what keeps
the arms honest — an arm whose define set shows `-DGROUP_BARRIER=1` is misconfigured,
not an experiment.

`MATMUL_SPOTCHECK=1` costs **zero** measured cycles: it runs at `main.c:586`, after the
`printf` of the cycle count at 581. Every arm self-checks.

MSHR CSRs are derived per shape at compile time from `GEMM_M/N/P` in the generated
`data_gemm.h` (`software/runtime/mshr_cfg.h`) — no per-arm tuning needed. Gate every compile line on **both**:

```sh
grep -o '\-DMSHR_CFG_BANKFULL_BP=[0-9]*' build.log   # expect =1
grep -o '\-DMSHR_MERGE_REQS=[0-9]*'      build.log   # expect =16, NOT the default 4
```

**Build hygiene:** `rm -f` the binary before each rebuild (the target depends on
`main.c.o`, not the define set, so it otherwise reports success without rebuilding), and
stage each ELF to an absolute private path `hardware/s8_<prec>_<M>x<N>x<P>.elf` —
never run from `software/bin`, which is shared and read at simulation time 0.

### Audit hook

To confirm an ELF's barrier state after the fact, count `sfence.vma` inside
`matmul_8xVL` (`0x80000188`-`0x800005f8`): **2 = `GBAR_PLOOP` only = barrier off**,
**6 = per-step barrier on**. Filenames are not reliable; the binary is.

---

## 6. Sweep plan

### 6a. Recommended: the iso-work A-share ladder

Total work `M*N*P` held **constant** so the only variable is the A-share degree — which
is the quantity the whole group-MSHR design exists to exploit.

**fp16** — `M*N*P = 1,073,741,824` on every rung:

| shape | A-share | L1 | est cyc | est h |
|---|---|---|---|---|
| `512x2048x1024` | 16-way | 7.00 MiB | 291k | ~8 |
| `1024x2048x512` | 8-way | 7.00 MiB | 291k | ~8 |
| `2048x1024x512` | 4-way | 7.00 MiB | 291k | ~8 |
| `4096x512x512` | 2-way | 8.51 MiB | 291k | ~8 |
| `8192x256x512` | 1-way | 12.27 MiB | 291k | ~8 |

**fp32** — `M*N*P = 536,870,912`; the 1-way rung is **impossible** (`8192x128x512`
needs 20.3 MiB > 14.5):

| shape | A-share | L1 | est cyc | est h |
|---|---|---|---|---|
| `512x1024x1024` | 16-way | 8.00 MiB | 291k | ~8 |
| `1024x1024x512` | 8-way | 8.00 MiB | 291k | ~8 |
| `2048x512x512` | 4-way | 9.01 MiB | 291k | ~8 |
| `4096x256x512` | 2-way | 12.52 MiB | 291k | ~8 |

**9 arms, ~72 h of fleet time, ~8-10 h wall-clock** run in parallel.

### 6b. What I would NOT do

Porting the 21 legal shapes from the 4x4 list. At 4x4, 26 of the matched pairs were
**cycle-identical** because the mechanism never fired, and they are all M >= 512 —
the same regime. That is ~21 arms x 8 h to re-learn "no change".

### 6c. Gating before dispatch

1. 8x8 image builds, and both gate greps in 4c pass.
2. **One pilot arm** (`512x2048x1024` fp16) completes and its spotcheck passes.
   Confirms the toolchain, the mesh, the derived MSHR config, and the runtime estimate
   before committing 9 arms x 8 h.
3. Only then dispatch the rest.

### 6d. Comparison arms

Each rung needs its 4x4 counterpart to be a scale-up measurement rather than a number.
The 4x4 data does **not** contain these shapes, so either add 4x4 runs of the same 9
shapes (cheap: ~1-2 h each) or state the comparison as 8x8-internal (share degree 16 ->
1) and drop the cross-mesh claim.

---

### 6e. Fleet resourcing — memory caps a badile, clock caps an arm

**Measured anchor (badile07, live 4x4 VCS arm):** `mempool_simvopt` RSS = **2.02 GiB**,
99.6% of one core. Node: 62 GiB total, ~55 GiB available.

8x8 instantiates 4x the design (1024 cores / 64 groups / 16384 banks). Simulator memory
tracks instantiated state close to linearly, so budget **~7-9 GiB per 8x8 sim**.
**This is an extrapolation** — no 8x8 image exists yet. The pilot arm (6c) must report
actual RSS before any wide dispatch.

Per node: 62 GiB total, ~54-57 GiB free on idle machines, badist reserves
`reserve_mem_gb: 8` -> **~46 GiB placeable**.

| declared `mem_gb` | jobs/node by memory | by CPU (24 threads, simv single-threaded) |
|---|---|---|
| 4 (current spec, correct for 4x4) | 11 | 24 |
| **10 (recommended for 8x8)** | **4** | 24 |
| 8 (if the pilot confirms RSS) | 5 | 24 |

Memory caps placement ~5x tighter than CPU does; these nodes will never be CPU-bound.

**Run fewer than memory allows.** The 9900X has two DDR channels and 32 MiB of L3, and
VCS event simulation is pointer-chasing and cache-hostile. Four concurrent 8 GiB working
sets contend for L3 and memory bandwidth in a way four 2 GiB sets do not — fitting is not
the same as running well. **Start at 2-3 per node** across more machines, and raise it
only after checking that a co-located arm's wall-clock matches a solo one. Establishing
that once (pilot solo, then two on one node) sets the shape of every later sweep.

**Action at dispatch:** `hardware/badist_specs/teranoc.json` declares `mem_gb: 4` — right
for 4x4, **2.5x too low for 8x8**. Under-declaring makes badist pack ~11 jobs onto a node
that holds 4, and they swap. Raise it for the 8x8 arms.

**Fleet as of 2026-08-22:** no longer badile-only — `badile01-49` + `larain1-13` +
`fenga1,3,4,7,8,9` = **67 hosts, ~2800 threads, ~9.7 TB free RAM**. Memory is now decisively
not a fleet constraint.

But **per-core clock is what sets wall-clock per arm**, because simv is single-threaded:

| family | threads/node | RAM | clock | per-arm |
|---|---|---|---|---|
| badile | 24 | 64 G | ~4.4 GHz | **fastest** |
| fenga3 | 96 | 1.5 T | 4.05 GHz | fast |
| larain | 128 | 512 G-1 T | 2.25-2.45 GHz | **~1.8x slower** |

So send the 9-arm ladder to **badile / fenga3** (latency), and reserve larain for a wide sweep
where arm-count is the bottleneck (throughput). `fenga1` is our own host: capped at 3 concurrent
arms via `policy.max_occupied_load_frac = 0.10`, and ranked last for long jobs — exclude it
explicitly for any wide submit.

For the 9-arm ladder none of this binds. The limits stay **wall-clock** (~8 h/arm) and the
**VCS licence** (100 seats).

### 6f. Fleet inventory — tested 2026-08-22

Every larain/fenga host was probed for four things before being added: SSH, **account
validity**, a writable node-local `/scratch`, and executability of the shared simv over
`/usr/scratch/fenga1`. `suninfo` confirms this is the complete inventory of both families
(no larain14+; fenga5/fenga6 do not exist).

| host | threads | RAM | CPU / clock | verdict |
|---|---|---|---|---|
| `badile01-49` | 24 | 64 G | Ryzen 9900X, ~4.4 GHz | usable — **fastest per arm** |
| `larain1,2,3,7,8,9` | 128 | 512 G | EPYC-7742, 2.25 GHz | usable — throughput |
| `larain4,5,6,10-13` | 128 | 1 T | EPYC-7763, 2.45 GHz | usable — throughput |
| `fenga1` | 96 | 1.5 T | EPYC 9274F, 4.05 GHz | usable — **our host, capped at 3** |
| `fenga2` | 96 | 1.5 T | EPYC 9274F, 4.05 GHz | **EXCLUDED — account not valid** |
| `fenga3` | 96 | 1.5 T | EPYC 9274F, 4.05 GHz | usable — fast *and* large |
| `fenga4` | 12 | 256 G | Xeon E5-2643 v4, 3.4 GHz | usable — small |
| `fenga7,8,9` | 32 | 384 G | Xeon Gold 6226R, 2.9 GHz | usable |

**The `fenga2` failure mode is a trap.** SSH *succeeds* and the rejection arrives as a
text banner (`This account (zexifu/620771) is not valid on fenga2.ee.ethz.ch`), so a
"can I ssh there" check based on the exit code passes it. Assert on a token instead:

```sh
R=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware/build_vcs_reuse32/mempool_simvopt
for h in larain{1..13} fenga{1,2,3,4,7,8,9}; do
  out=$(timeout 25 ssh -x -o BatchMode=yes -o ConnectTimeout=8 "$h" \
        "echo TOKEN_\$(id -un); [ -x $R ] && echo SIMV_OK; [ -w /scratch ] && echo SCR_OK" 2>&1)
  echo "$out" | grep -q '^TOKEN_zexifu$' && echo "$h USABLE" || echo "$h EXCLUDE"
done
```

Current `~/.badist.json`:

```json
"hosts": {
  "include": ["badile01-badile49", "larain1-larain13",
              "fenga1", "fenga3", "fenga4", "fenga7", "fenga8", "fenga9"],
  "exclude": ["fenga2", "fenga5", "fenga6"]
},
"policy": { "max_occupied_load_frac": 0.10, "long_job_s": 1800,
            "avoid_occupied_for_long_jobs": true, "drain_never_evict": true }
```

**Why `max_occupied_load_frac = 0.10`.** badist has **no per-host job cap**. With fenga1
in the pool it probed `occupied=true` but still admitted **8** concurrent arms — on top of
the local GUI runs. 0.10 takes that to **3**. Measured after the change:

| host | cores | load | occupied | cap @mem_gb 4 | cap @mem_gb 10 |
|---|---|---|---|---|---|
| `fenga1` | 96 | 62.5 | yes | **3** | **3** |
| `fenga3` | 96 | 23.8 | yes | 7 | 7 |
| `badile07` | 24 | 1.0 | no | 11 | 4 |
| `larain13` | 128 | 27.3 | yes | 9 | 9 |

The change is **fleet-wide by construction** — it also makes us a politer guest on
colleagues' occupied desktops, consistent with `drain_never_evict`. Idle nodes are
unaffected: the cap only applies when `occupied` is true, which is why `badile07` still
offers 11. For any submit wide enough to reach fenga1, put it in `exclude` for that submit
rather than relying on long-job ranking.

Two hosts placement will decline on its own, no action needed: `larain1` had **1 G** free
on `/scratch` (spec asks `disk_gb: 5`) and `larain6` **0 G**; `larain8` sits at load ~195
on 128 cores and reports "busy, no free cores".

## 7. Open items

- **The M >= 512 rule excludes the entire 128-family from 8x8.** Tonight's headline
  results — the 21x reuse-target wins and the +1168% idea-2 regression — are all
  `M = 128`. They **cannot be reproduced at 8x8** with `kernel_size = 8`.
  `KERNEL_SIZE=2` unlocks all 12 rejected shapes and `KERNEL_SIZE=4` unlocks the 8
  `M=256` ones, but that changes LMUL and burst behaviour, so those arms would not be
  comparable to the `kernel_size=8` 4x4 data. **Decide this before dispatch** — it
  determines whether the 4x4 headline results are portable at all.
- Runtime model is a loose fit; the pilot arm in 6c is what replaces it with a measurement.
- 45%-of-peak efficiency is an assumption carried over from 4x4; 8x8 may be lower, which
  would push every estimate up proportionally.
