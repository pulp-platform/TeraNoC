# Four open decisions — 2026-08-25

Each is blocked on a judgement call, not on work. Nothing here has been actioned.
Background: `FINDINGS.md`, `rh_livelock_root_cause.md`.

---

## 1. Decode-kernel benchmark: D=256 or D=128?

**What is already done.** The decode work-distribution kernel is implemented and builds clean for
both meshes. It turned out to need **no new inner kernel and no DMA transpose**:

```
C[B][I] = A[B][D] x W[D][I]        B = batch (32), D = 5120, I = 17408
  A is [B][D] row-major -> A[b][d] contiguous in d -> scalar flh broadcast
  W is [D][I] row-major -> W[d][p:p+VL] contiguous -> vector load, BURSTS
```

That is exactly what `matmul_8xVL` already does. Only the *work split* changes: the prefill path
divides M across groups, which is why `M = B = 32` returns `-6` (`dim_group = 32/64 = 0`). The
decode split never touches M:

```
row_chunk = cid % n_row_chunks     n_row_chunks = B / KERNEL_SIZE = 4
p_block   = cid / n_row_chunks     n_p_blocks   = active_cores / n_row_chunks
```

`row_chunk` varies fastest **on purpose**: cores sharing a `p_block` read identical W bytes, and
consecutive core ids sit in the same group (`hartid = (group<<4)|tile`), so the group MSHR
burst-merges them and **W leaves L2 once, not four times**.

Both candidate shapes fill their mesh exactly and land on the 128 B optimum:

| mesh | shape | P-blocks × row-chunks | tasks | cores | slice |
|---|---|---|---:|---:|---|
| 4×4 | B=32, D=?, I=4096 | 64 × 4 | 256 | 256 | 128 B |
| 8×8 | B=32, D=?, I=16384 | 256 × 4 | 1024 | 1024 | 128 B |

**The decision.** L1 is **4 MiB at 4×4, 16 MiB at 8×8** (`arch.ld.c:20`, `L1_BANK_SIZE` is bytes):

| D | 4×4 working set | 8×8 working set | fits today | survives double buffering |
|---:|---:|---:|---|---|
| **256** | 2.27 MiB / 4 | 9.02 MiB / 16 | yes | **no** (budget halves) |
| **128** | 1.26 MiB / 4 | 5.01 MiB / 16 | yes | **yes** |

- **D=256** — larger contraction, so a better efficiency reading. But the current kernel does not
  double-buffer; when it does, this shape no longer fits and the measurement is not reusable.
- **D=128** — survives the future kernel, but N=128 measured only **55.1%** median in the sweep
  (§2 of FINDINGS), so it reads low for a reason that has nothing to do with the distribution.

**Recommendation: run D=256 first.** The question this benchmark answers is *"does the new split
work at all"*, and D=256 answers it with the least confounding. Then run D=128 as the
double-buffer-compatible point once the first number is known — the pair also gives the N slope
for this kernel, which is worth having on its own.

ELFs already built: `hardware/dec8_32x256x16384.elf`, `hardware/dec4_32x256x4096.elf`.

---

## 2. The 8191 hold-window GUI run

**What is ready.** `hardware/s8w8_fp16_4096x32x512.elf`, verified to write
`hold_window_single = hold_window_burst = 8191`, `serve_timeout = 8191`, and differing from its
2047 baseline only in those constants.

**The catch that makes this a decision.** The 8191 write is **refused by every existing image**.
`HoldCntHwMax` was only wired to the package constant in `3756ac13`; every built image predates
it. Against an old image the CSR silently drops the write and runs 2047 — exactly what voided the
earlier 4095 campaign. So the run needs a **fresh buildpath**, which forces an RTL rebuild:

```sh
cd hardware
make sim -B config=terapool_spatz4_fpu_8x8 \
  preload=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware/s8w8_fp16_4096x32x512.elf \
  buildpath=build_4_gui_8191_4096x32x512 group_mshr_merge_reqs=16
```

**Gate on the first arm:** `grep -c 'MSHR. cfg REJECTED' transcript` must be **0**. Absence of
that line plus `[MSHRCFG] all 64 groups ENABLED` is the proof 8191 took. Never gate on `RANGE` —
`MSHR_STATUS_RANGE` is never printed and that grep can only ever return 0.

**What to expect, honestly.** `4096x32x512` is **mechanism C** (M ≥ 4096, singles bypass,
`RH = 0`, `tmo = 425`). The 8191 windows act on the *hold* paths; the single hold is inert here
because singles bypass. The burst window is the live one (burst target 8, B slice 512 B, 8 cores
genuinely sharing the line), so this tests whether the burst cohort was merely mistimed. It does
**not** address mechanism C's timeouts, which is what dominates this shape's 19% utilisation.

Disk: a GUI WLF reached 347 GB last time and fenga1 is at 723 GB free. Prefer
`add_group_cores.tcl <g> 0 1` (two tiles) over all 16.

---

## 3. Redundant running arms (~17 seats)

**The situation.** 17 arms are in `state=running` while a *sibling copy has already produced the
result*. 12 have a recorded row with its probe archive banked; 5 have a finished transcript the
scrape has not yet picked up.

**Why nothing catches them today.**

- `find_duplicate_arms.py` looks for **the same arm running in two batches at once**. These pairs
  never coexist as two *running* jobs — the winner finished first — so it correctly reports none.
- `feasibility.delivered()` gates at **dispatch** time. It was False when these were queued and
  became True when the sibling finished. Nothing re-checks afterwards.
- `salvage_zombies.py` releases seats for **finished-but-parked** sims. It deliberately leaves
  *unfinished* sims alone, because a zombie is often further along than the copy that replaced it.
  The 17 are actively simulating, so its caution correctly excludes them.

The three tools are each right; the gap is between them.

**The proposal.** Add a `delivered()`-based sweep to the dedup loop: any arm in `state=running`
whose result is already recorded gets cancelled, with the discipline used for every manual kill so
far — verify the result exists *and* its probe archive is banked, cancel the specific job, kill by
PID matched on exact `/proc/<pid>/cwd`, then sweep the fleet with `ssh -n` to confirm no survivor.

**Guards worth building in:** skip the 5 transcript-only arms until the scrape records them (so a
partial cannot be mistaken for a result); never kill an arm whose only row is a livelock without a
real cycle count.

**Cost of not doing it:** ~17 Questa seats, each running up to 48 h to reproduce a number already
held — and it recurs, because the race is structural.

---

## 4. Gating the N=32 / P=2048 family (6 arms)

**The situation.** Six manifest cells cannot finish:

```
fp16_512x32x2048    0.64% util   118x over ideal      B slice  256 B
fp32_512x32x2048    1.32% util    59x over ideal      B slice  512 B
fp16_1024x32x2048   0.76% util    77x over ideal      B slice  512 B
fp32_1024x32x2048   1.32% util    91x over ideal      B slice 1024 B
fp16_2048x32x2048   0.69% util    80x over ideal      B slice 1024 B
fp32_2048x32x1024   (same family)
```

`fp32_1024x32x2048` has now failed **three times on three nodes**, every time `rc=124,
timed_out=1, wall_s=86400`. Not infrastructure — at ~1% utilisation an 8–16 k-cycle problem needs
over a million cycles, and no wall clock accommodates that.

**This is mechanism B**, not the livelock: none is sub-burst, all have `RH = 0`. Extending the
wall clock would not rescue them either — it would simply cost 48 h instead of 24 h per attempt.

**The proposal.** Add the family to `feasibility.stalling()` the way the livelock shapes are
gated — **on evidence, not on a predicate**: block only an arm that both matches (N ≤ 32,
P ≥ 2048) *and* has a recorded timeout with `util < 2%` and `RH = 0`. An arm with no history is
always allowed to try, which is the rule that stopped the livelock gate over-reaching.

**What it costs.** Six cells stay permanently blank in the campaign. That is the real trade: the
sweep would no longer be able to claim full manifest coverage, and the blank cells must be
explained in the results doc rather than looking like missing work.

**What it saves.** Roughly six 24-hour Questa seats, repeated at every retry cycle.

**Recommendation: gate them, and record the six in `FINDINGS.md` §3B as a measured result** —
"cannot complete at ~1% utilisation" is itself a finding about the low-N mechanism, and a more
useful one than six empty cells.
