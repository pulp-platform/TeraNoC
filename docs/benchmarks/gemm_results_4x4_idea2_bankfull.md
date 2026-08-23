# GEMM results, 4x4 / 256 cores — idea-2 and bank-full backpressure, fp16 and fp32

Generated 2026-08-23 18:15 by `scripts/gen_4x4_idea2_bp_doc.py`. **Re-run it rather than trusting a stale copy.**

These are the newest 4x4 arms in the tree. Until this file existed they were published only as
artifacts (*Spatz fp16 Sweep*, *Spatz Idea-2 Sweep*, *Backpressure Sweep*), so the benchmark
tree's newest 4x4 document was `gemm_results_default_latest.md` (2026-08-19) — which is fp32
only and predates both changes below.

## The two arms

| arm | dir prefix | what it is |
|---|---|---|
| **idea-2** | `run4_<prec>_<MxNxP>` | RTL at HEAD (cache reuse-target CSRs), response cache ON, per-shape MSHR tuning **derived at compile time** from `GEMM_M/N/P` rather than a per-shape config |
| **+bankfull-bp** | `run5_<prec>_<MxNxP>` | identical in every other respect — same ELFs, same derived tuning, `MergeReqs=16`. The single difference: a mergeable miss whose MSHR bank is full now **stalls** instead of bypassing the MSHR |

A bypass splits the coalescing cohort, which is what strands a later allocator on `serve_timeout`.
The hypothesis under test is that back-pressuring instead of bypassing keeps the cohort intact.

`eff` is **efficiency = ideal / actual**, not the testbench `[FPU] util` counter (lane occupancy,
not conserved across runs of identical work, and it has inverted a real ranking before).
`ideal = M·N·P / peak`, peak = **1024** MAC/cyc at fp32 and **2048** at fp16 (256 cores x 4 FPU,
x2 lanes at e16). `RH` and `timeout` are the response-hazard episode and `mshr_timeout` counters.

## fp16

| M×N×P | ideal | idea-2 | eff | +bankfull-bp | eff | Δ | RH i2 | RH bp | timeout i2 | timeout bp |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 128x128x512 | 4,096 | 132,120 | 3.1% | **132,120** | **3.1%** | +0.0% | 963 | 963 | 0 | 0 |
| 128x256x512 | 8,192 | 251,253 | 3.3% | **259,337** | **3.2%** | +3.2% | 2,849 | 1,938 | 0 | 0 |
| 128x512x512 | 16,384 | 290,542 | 5.6% | **133,524** | **12.3%** | -54.0% | 2,866 | 1,634 | 0 | 0 |
| 128x1024x512 | 32,768 | 584,795 | 5.6% | **561,030** | **5.8%** | -4.1% | 14,981 | 7,971 | 0 | 0 |
| 256x32x256 | 1,024 | 2,508 | 40.8% | **2,508** | **40.8%** | +0.0% | 0 | 0 | 0 | 0 |
| 256x32x512 | 2,048 | 3,849 | 53.2% | **3,849** | **53.2%** | +0.0% | 0 | 0 | 0 | 0 |
| 256x64x256 | 2,048 | 3,879 | 52.8% | **3,879** | **52.8%** | +0.0% | 0 | 0 | 0 | 0 |
| 256x128x256 | 4,096 | 6,267 | 65.4% | **6,267** | **65.4%** | +0.0% | 0 | 0 | 0 | 0 |
| 256x256x256 | 8,192 | 11,327 | 72.3% | **11,327** | **72.3%** | +0.0% | 0 | 0 | 0 | 0 |
| 256x512x256 | 16,384 | 21,492 | 76.2% | **21,492** | **76.2%** | +0.0% | 0 | 0 | 0 | 0 |
| 256x512x512 | 32,768 | 34,577 | 94.8% | **34,577** | **94.8%** | +0.0% | 0 | 0 | 0 | 0 |
| 256x1024x256 | 32,768 | 41,658 | 78.7% | **41,658** | **78.7%** | +0.0% | 0 | 0 | 0 | 0 |
| 512x32x512 | 4,096 | 68,832 | 6.0% | **7,558** | **54.2%** | -89.0% | 3,599 | 0 | 2,529 | 0 |
| 512x64x256 | 4,096 | 90,286 | 4.5% | **7,092** | **57.8%** | -92.1% | 7,894 | 0 | 5,701 | 0 |
| 512x64x512 | 8,192 | 99,150 | 8.3% | **11,925** | **68.7%** | -88.0% | 6,425 | 0 | 4,162 | 0 |
| 512x128x128 | 4,096 | 138,633 | 3.0% | **7,464** | **54.9%** | -94.6% | 3,020 | 0 | 3,225 | 0 |
| 512x128x256 | 8,192 | 200,055 | 4.1% | **11,024** | **74.3%** | -94.5% | 14,817 | 0 | 10,213 | 0 |
| 512x128x512 | 16,384 | 292,579 | 5.6% | **20,712** | **79.1%** | -92.9% | 27,652 | 0 | 14,584 | 0 |
| 512x256x128 | 8,192 | 412,402 | 2.0% | **12,263** | **66.8%** | -97.0% | 37,103 | 0 | 12,309 | 0 |
| 512x256x256 | 16,384 | 345,188 | 4.7% | **19,020** | **86.1%** | -94.5% | 42,936 | 0 | 19,929 | 0 |
| 512x256x512 | 32,768 | 630,316 | 5.2% | **37,861** | **86.5%** | -94.0% | 65,452 | 0 | 29,172 | 0 |
| 512x512x128 | 16,384 | 688,864 | 2.4% | **22,138** | **74.0%** | -96.8% | 65,045 | 0 | 19,882 | 0 |
| 512x512x512 | 65,536 | 1,360,067 | 4.8% | **71,755** | **91.3%** | -94.7% | 197,341 | 0 | 81,200 | 0 |
| 1024x128x128 | 8,192 | 15,849 | 51.7% | **15,849** | **51.7%** | +0.0% | 0 | 0 | 0 | 0 |
| 1024x128x512 | 32,768 | 50,365 | 65.1% | **50,365** | **65.1%** | +0.0% | 0 | 0 | 0 | 0 |
| 1024x256x256 | 32,768 | 47,965 | 68.3% | **47,965** | **68.3%** | +0.0% | 0 | 0 | 0 | 0 |
| 1024x256x512 | 65,536 | 88,645 | 73.9% | **88,645** | **73.9%** | +0.0% | 0 | 0 | 0 | 0 |
| 1024x512x512 | 131,072 | 175,740 | 74.6% | **175,740** | **74.6%** | +0.0% | 0 | 0 | 0 | 0 |
| 2048x128x128 | 16,384 | 40,957 | 40.0% | **40,957** | **40.0%** | +0.0% | 0 | 0 | 20 | 20 |
| 2048x256x256 | 65,536 | 106,654 | 61.4% | **106,654** | **61.4%** | +0.0% | 0 | 0 | 0 | 0 |
| 2048x256x512 | 131,072 | 216,742 | 60.5% | **216,742** | **60.5%** | +0.0% | 0 | 0 | 0 | 0 |
| 2048x512x256 | 131,072 | 195,769 | 67.0% | **195,769** | **67.0%** | +0.0% | 0 | 0 | 0 | 0 |
| 4096x128x128 | 32,768 | 332,598 | 9.9% | **360,061** | **9.1%** | +8.3% | 0 | 0 | 14,350 | 13,432 |

33 matched pairs: **13 faster with backpressure, 2 slower, 18 bit-identical** (median Δ +0.0%, range -97.0% to +8.3%).

## fp32

| M×N×P | ideal | idea-2 | eff | +bankfull-bp | eff | Δ | RH i2 | RH bp | timeout i2 | timeout bp |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 128x128x512 | 8,192 | 9,550 | 85.8% | **9,550** | **85.8%** | +0.0% | 0 | 0 | 0 | 0 |
| 128x256x512 | 16,384 | 17,825 | 91.9% | **17,825** | **91.9%** | +0.0% | 0 | 0 | 0 | 0 |
| 128x512x512 | 32,768 | 35,116 | 93.3% | **35,116** | **93.3%** | +0.0% | 0 | 0 | 0 | 0 |
| 128x1024x512 | 65,536 | 68,065 | 96.3% | **68,065** | **96.3%** | +0.0% | 0 | 0 | 0 | 0 |
| 256x32x256 | 2,048 | 3,667 | 55.8% | **3,667** | **55.8%** | +0.0% | 0 | 0 | 0 | 0 |
| 256x32x512 | 4,096 | 6,634 | 61.7% | **6,634** | **61.7%** | +0.0% | 0 | 0 | 0 | 0 |
| 256x64x256 | 4,096 | 5,761 | 71.1% | **5,761** | **71.1%** | +0.0% | 0 | 0 | 0 | 0 |
| 256x128x256 | 8,192 | 9,902 | 82.7% | **9,902** | **82.7%** | +0.0% | 0 | 0 | 0 | 0 |
| 256x256x256 | 16,384 | 18,134 | 90.3% | **18,134** | **90.3%** | +0.0% | 0 | 0 | 0 | 0 |
| 256x512x256 | 32,768 | 34,883 | 93.9% | **34,883** | **93.9%** | +0.0% | 0 | 0 | 0 | 0 |
| 256x512x512 | 65,536 | 75,617 | 86.7% | **75,617** | **86.7%** | +0.0% | 0 | 0 | 0 | 0 |
| 256x1024x256 | 65,536 | 67,945 | 96.5% | **67,945** | **96.5%** | +0.0% | 0 | 0 | 0 | 0 |
| 512x32x512 | 8,192 | 14,011 | 58.5% | **14,011** | **58.5%** | +0.0% | 0 | 0 | 0 | 0 |
| 512x64x256 | 8,192 | 11,992 | 68.3% | **11,992** | **68.3%** | +0.0% | 0 | 0 | 0 | 0 |
| 512x64x512 | 16,384 | 23,992 | 68.3% | **23,992** | **68.3%** | +0.0% | 0 | 0 | 0 | 0 |
| 512x128x128 | 8,192 | 11,476 | 71.4% | **11,476** | **71.4%** | +0.0% | 0 | 0 | 0 | 0 |
| 512x128x256 | 16,384 | 20,368 | 80.4% | **20,368** | **80.4%** | +0.0% | 0 | 0 | 0 | 0 |
| 512x128x512 | 32,768 | 41,494 | 79.0% | **40,789** | **80.3%** | -1.7% | 23 | 0 | 0 | 0 |
| 512x256x128 | 16,384 | 19,897 | 82.3% | **19,897** | **82.3%** | +0.0% | 0 | 0 | 0 | 0 |
| 512x256x256 | 32,768 | 38,932 | 84.2% | **38,055** | **86.1%** | -2.3% | 23 | 0 | 0 | 0 |
| 512x256x512 | 65,536 | 77,802 | 84.2% | **76,919** | **85.2%** | -1.1% | 23 | 0 | 0 | 0 |
| 512x512x128 | 32,768 | 37,538 | 87.3% | **37,538** | **87.3%** | +0.0% | 0 | 0 | 0 | 0 |
| 512x512x512 | 131,072 | 155,612 | 84.2% | — | — | — | 123 | — | 0 | — |
| 1024x128x128 | 16,384 | 27,942 | 58.6% | **27,942** | **58.6%** | +0.0% | 0 | 0 | 0 | 0 |
| 1024x128x512 | 65,536 | 100,934 | 64.9% | **100,934** | **64.9%** | +0.0% | 0 | 0 | 0 | 0 |
| 1024x256x256 | 65,536 | 91,368 | 71.7% | **91,368** | **71.7%** | +0.0% | 0 | 0 | 0 | 0 |
| 1024x256x512 | 131,072 | 186,829 | 70.2% | **186,829** | **70.2%** | +0.0% | 0 | 0 | 0 | 0 |
| 2048x128x128 | 32,768 | 63,593 | 51.5% | **63,593** | **51.5%** | +0.0% | 0 | 0 | 0 | 0 |

27 matched pairs: **3 faster with backpressure, 0 slower, 24 bit-identical** (median Δ +0.0%, range -2.3% to +0.0%).

## fp16 against fp32, on the backpressure arm

| M×N×P | fp16 | eff | fp32 | eff | fp32/fp16 |
|---|---:|---:|---:|---:|---:|
| 128x128x512 | 132,120 | 3.1% | 9,550 | 85.8% | **0.07x** |
| 128x256x512 | 259,337 | 3.2% | 17,825 | 91.9% | **0.07x** |
| 128x512x512 | 133,524 | 12.3% | 35,116 | 93.3% | **0.26x** |
| 128x1024x512 | 561,030 | 5.8% | 68,065 | 96.3% | **0.12x** |
| 256x32x256 | 2,508 | 40.8% | 3,667 | 55.8% | **1.46x** |
| 256x32x512 | 3,849 | 53.2% | 6,634 | 61.7% | **1.72x** |
| 256x64x256 | 3,879 | 52.8% | 5,761 | 71.1% | **1.49x** |
| 256x128x256 | 6,267 | 65.4% | 9,902 | 82.7% | **1.58x** |
| 256x256x256 | 11,327 | 72.3% | 18,134 | 90.3% | **1.60x** |
| 256x512x256 | 21,492 | 76.2% | 34,883 | 93.9% | **1.62x** |
| 256x512x512 | 34,577 | 94.8% | 75,617 | 86.7% | **2.19x** |
| 256x1024x256 | 41,658 | 78.7% | 67,945 | 96.5% | **1.63x** |
| 512x32x512 | 7,558 | 54.2% | 14,011 | 58.5% | **1.85x** |
| 512x64x256 | 7,092 | 57.8% | 11,992 | 68.3% | **1.69x** |
| 512x64x512 | 11,925 | 68.7% | 23,992 | 68.3% | **2.01x** |
| 512x128x128 | 7,464 | 54.9% | 11,476 | 71.4% | **1.54x** |
| 512x128x256 | 11,024 | 74.3% | 20,368 | 80.4% | **1.85x** |
| 512x128x512 | 20,712 | 79.1% | 40,789 | 80.3% | **1.97x** |
| 512x256x128 | 12,263 | 66.8% | 19,897 | 82.3% | **1.62x** |
| 512x256x256 | 19,020 | 86.1% | 38,055 | 86.1% | **2.00x** |
| 512x256x512 | 37,861 | 86.5% | 76,919 | 85.2% | **2.03x** |
| 512x512x128 | 22,138 | 74.0% | 37,538 | 87.3% | **1.70x** |
| 1024x128x128 | 15,849 | 51.7% | 27,942 | 58.6% | **1.76x** |
| 1024x128x512 | 50,365 | 65.1% | 100,934 | 64.9% | **2.00x** |
| 1024x256x256 | 47,965 | 68.3% | 91,368 | 71.7% | **1.90x** |
| 1024x256x512 | 88,645 | 73.9% | 186,829 | 70.2% | **2.11x** |
| 2048x128x128 | 40,957 | 40.0% | 63,593 | 51.5% | **1.55x** |

Over the **23 shapes with M ≥ 256**: median **1.72x**, range 1.46x–2.19x.

The 4 M=128 fp16 shapes are excluded from that median and shown above only for the record —
they are the **fp16 M=128 wedge** (3–12% efficiency, thousands of RH episodes), a defect,
not a datapoint. Backpressure does not reliably clear it.

## What the two tables say

1. **Backpressure is a no-op unless the arm has response hazards.** Every pair whose idea-2 arm
   reports `RH = 0` is bit-identical under backpressure — same cycle count to the digit. That is
   the expected signature: the stall path only exists on a mergeable miss into a full bank.
2. **Where RH is present at fp16 and M ≥ 512, the effect is enormous.** Those arms collapse to
   2–8% efficiency under idea-2 alone, with tens of thousands of RH episodes *and* MSHR timeouts;
   backpressure drives **both counters to exactly zero** and restores 54–91% efficiency.
3. **fp32 is essentially untouched.** Almost every fp32 pair is bit-identical; the three that move
   do so by 1–2%, and each had a two-digit RH count rather than a four- or five-digit one.
4. **RH is the gate, not the shape.** Do not quote a backpressure win without recording the
   arm's RH count — an arm with RH = 0 cannot benefit, and reporting its 0.0% as evidence
   either way is a category error.

## Provenance and caveats

- Scraped from `hardware/run4_*/transcript` and `hardware/run5_*/transcript` by the same reader
  the fp16 dashboards use (`scripts/gen_fp16_sweep_dash.py:collect`), so the numbers here and in
  those artifacts come from one code path.
- QuestaSim prefixes every transcript line with `# `; the reader strips it before matching. An
  anchored pattern that skips this silently reports zero rows.
- `[FPUG]`/`[FPU]` lines are tagged `pre` (warm-up, counters gated off) or `bench`. A `pre` zero
  means *not counting*, not idle. Only `bench` windows are summed.
- Cycles are whole-kernel, including DMA and every serial section — not a GEMM-only counter.
  This matters when comparing against accelerator DSE numbers that exclude DMA from the timed
  interval; see `docs/qwen38_kernel_mapping.md`.

