# fp16 sp-fmatmul deadlock — investigation state

## ✅ CONFIRMED BY CONTROLLED EXPERIMENT — `spatz_vfu.sv:141`

Three fenced phases, controls first, on **unfixed** RTL (`build_vfutag`). Verdicts were written
down *before* the run, including the two outcomes that would have refuted the hypothesis:

| phase | content | predicted | result |
|---|---|---|---|
| **A** | e16 vector ops, **no** adjacent `mul` | pass | ✅ `A_E16_NO_MUL_OK` |
| **B** | `mul` + **e32** vector op | pass | ✅ `B_MUL_PLUS_E32_OK` |
| **C** | `mul` + **e16** vector op | **wedge** | ✅ **WEDGED, 256/256 harts** |

The wedge is at the phase-C entry, all 256 cores:

```
80000480: li       a0, 64                     <- 173 harts stop here
80000484: vsetvli  a0, a0, e16, m2, ta, ma    <-  82 harts stop here
80000488: mul      a0, s2, s3                 <- scalar op -> VFU at EW_32
8000048c: vfadd.vv v6, v0, v0                 <-   1 hart  stops here (e16 op)
```

`raw_sum = 256000` against `raw_cap = 256000` — **100% pegged**, a genuine hang, not the
tracing-disabled false positive that the classifier used to produce.

### What this establishes

**Neither e16 alone nor `mul` alone breaks anything — only the pairing.** Phase A proves e16 vector
work is fine. Phase B proves a `mul` offloaded to the VFU is fine. Phase C differs from B in one
respect only: the `vsetvli` before it sets `e16` instead of `e32`. That is exactly the condition
under which `pending_results` (`:141`) reads the live `spatz_req.vtype.vsew` to judge a result
belonging to an *earlier* instruction, builds `8'hff` where only `4'hf` can ever arrive, and leaves
`&(result_valid | ~pending_results)` false forever.

### Method note

The controls are what make this interpretable. A bare "fp16 hangs" observation is consistent with a
dozen mechanisms; A and B passing narrows it to the pairing and excludes both single-variable
explanations in the same run. Registering the refuting outcomes in advance also mattered — an
earlier false HUNG on this very arm (`raw_sum=199`, tracing simply not enabled) would otherwise
have read as a phase-A wedge, i.e. as a refutation of a correct hypothesis.

Fix verification (`build_vfufix`, same probe ELF, one-word change) is still running; it had cleared
phase A and was executing phase B when the unfixed arm died.

---


## 2026-08-19 — ROOT CAUSE: `spatz_vfu.sv:141`, an element-width tag hazard

```systemverilog
// spatz_vfu.sv:141
assign pending_results = result_tag.wb ? (spatz_req.vtype.vsew == EW_32 ? 4'hf : 8'hff) : '1;
```

The **selector** (`result_tag.wb`) belongs to the instruction whose result is at the FU output.
The **element width** (`spatz_req.vtype.vsew`) is read from the **live incoming request**. With
`spatz_ipu.sv:12 Pipeline = 1`, those are different instructions whenever the pipe is non-empty.
`vfu_tag_t` (`:49-66`) **already carries `vsew`** (`:52`), captured from `spatz_req.vtype.vsew` at
issue (`:539`) and travelling with the operands through the pipeline. The correct width was right
there and simply was not used.

### The mechanism

1. Snitch has no multiplier — `snitch.sv:1043-1046` offloads `MUL`/`MULH`/`MULHSU`/`MULHU`. Every
   `mul` becomes a **Spatz VFU scalar op**, issued at `vsew = EW_32`, mask `4'hf`, and only lane 0
   is fed (`:780`, `:968`).
2. The IPU is pipelined, so the mul's result surfaces a cycle or more later.
3. If the *next* instruction sets `vsew = EW_16`, the mul's result is judged against `8'hff` —
   the idiom treats every non-`EW_32` width as if it were `EW_64`.
4. `&(result_valid | ~pending_results)` = `&(16'h000f | 16'hff00)` = `&16'hff0f` = **0**, forever.
5. `result_ready` (`:380`, `:392`) and `vfu_rsp_valid_o` (`:273`) never assert. The VFU is wedged,
   its operation queue fills, Snitch can no longer issue, and the core stops.

### Why this matches the trace evidence exactly

The wedge PC found independently from the per-hart traces was `0x800002d8`, and the two
instructions immediately before it are:

```
800002d0:  mul        a2, s10, a6      <- scalar op -> Spatz VFU at EW_32
800002d4:  vfmacc.vf  v0, ft7, v20     <- sets the live request to EW_16
800002d8:  addi       s10, s10, 8      <- LAST RETIRED on 254/256 harts
```

That is precisely the poison pairing. Two independent methods — trace localisation and an RTL
audit — converged on the same instruction pair.

### Why every earlier hypothesis failed

The bug is in the **VFU**, not the memory system. It has nothing to do with loads, stores, burst
eligibility, byte strobes, alignment, the MSHR, or `flh` vs `flw`. The store was simply where the
back-pressure became visible, exactly as the earlier correction suspected. fp32 is immune because
`vsew` stays `EW_32`, so the mask matches whichever instruction it is read from.

`valid_operations` at `:137` uses the same `EW_32 ? 4'hf : 8'hff` idiom but is **self-consistent** —
both the selector and the width come from `spatz_req` at issue — which is why only `:141` is a
hazard.

### The fix — one word

```diff
-assign pending_results = result_tag.wb ? (spatz_req.vtype.vsew == EW_32 ? 4'hf : 8'hff) : '1;
+assign pending_results = result_tag.wb ? (result_tag.vsew      == EW_32 ? 4'hf : 8'hff) : '1;
```

The invariant being restored: **whatever mask decided which lanes to FEED must be the mask that
decides when they are all DONE.** `valid_operations` (`:137`) builds the feed mask from
`spatz_req` at issue; `result_tag.vsew` is that same instruction's width carried forward, so the
two now refer to one instruction instead of two.

Applied and building as `build_vfufix`, which then re-runs the *same* probe ELF that wedges on
unfixed RTL, followed by the real fp16 matmul at 256x32x256.

Residual, deliberately not changed in the same edit: the `EW_32 ? 4'hf : 8'hff` two-way select is
independently questionable for `EW_8`/`EW_16` (it yields an 8-byte mask for every non-`EW_32`
width). It is *self-consistent* between `:137` and the fixed `:141`, so it is not this bug, and
folding a second change into the fix would make the A/B unreadable.

### Eliminated by RTL audit (17 agents, adversarially verified) — do not re-chase

| surface | verdict |
|---|---|
| `spatz_mem_req.size` (`spatz_vlsu.sv:1863`) | **Dead silicon.** Declared at `spatz_pkg.sv:294`, driven here, and *never read* anywhere in the compiled tree — `spatz_mempool_cc.sv:279-296` wires addr/write/data/strb/id/burst_len and drops it; `mempool_pkg.sv` has no such field to carry it. So the memory system cannot distinguish an e16 store from an e32 one at all. It is also unconditional (no `is_load` qualifier), so if it mattered `vle16` would break too. |
| VLSU byte arithmetic (`:1165` request partition, `:1086` commit partition) | **Clean, EW-invariant.** Both are byte-domain after the single conversion at `:190`; two elaboration `$error`s (`:1886`, `:1889`) force `MemDataWidth==ELEN` and `NrMemPorts==N_FU`, so the request-side and commit-side maxima are *identical expressions* at every `vsew`. Verified with a worked example and with parameters pinned from the failing build's own `compile.tcl` (NrMemPorts=4, MemDataWidthB=4, ELEN=32, VLEN=512). |
| Fork features — ParityDrain/TwinROB0, H1 runahead, block ROB alloc | **Clean.** Every quantity is byte- or word-granular, never element-granular (`commit_pair_active` tests `commit_counter_q[0][2:0]` and a byte difference). |
| Exact-equality commit completion (`:632-633`) | **Already refuted empirically.** The in-tree comment warns an e16 delta could overshoot into a permanent stall, but the sim-only `[VLSU OVERSHOOT]` probe added for exactly this fired **zero** times. |

**Left open by the audit, and deliberately not chased:** `spatz_vlsu.sv:942`
`mem_is_addr_unaligned = rs1[1:0] != 0`. The store address is `base + (j<<1)`, so at **odd `j`**
it is 2 mod 4 — unaligned — which the e32 control (`<<2`) can never reach. That flips the store
onto the single-element datapath (delta 2 instead of 4, width-dependent strobe at `:1821-1830`).
Genuinely e16-only and genuinely different; the runtime parity of `j` was never verified.

It does not need to be chased, because **phase C of the confirming test contains no memory traffic
at all** — it is `mul` + `vfadd.vv` in a loop. If phase C wedges, every VLSU hypothesis above
(including this one) is exonerated in a single measurement rather than one at a time.

### Confirming test

`software/apps/spatz_apps/sp-vfu-ew-tag-probe` runs three fenced phases, controls first:

| phase | content | expectation |
|---|---|---|
| A | e16 vector ops, **no** adjacent `mul` | pass |
| B | `mul` + **e32** vector op | pass |
| C | `mul` + **e16** vector op | **wedge** |

A and B passing while C wedges isolates it to the *pairing* — not e16 alone, not `mul` alone.
Codegen verified: 32 adjacent `mul`+`vfadd.vv v4` pairs at e32 and 32 `mul`+`vfadd.vv v6` at e16.

---


## 2026-08-19 (late) — LOCALISED: the wedge surfaces at the first `vse16.v`

Established from per-hart execution traces, not inference. Counting how many of the 256 harts ever
executed each PC in the hung `build_fp16b` run:

| instruction | PC | harts that executed it | executions |
|---|---|---|---|
| `vle16.v` (load) | `0x80000348` | **256 / 256** | 512 |
| `vle16.v` (load) | `0x80000394` | **256 / 256** | 512 |
| `vse16.v` (store) | `0x800002e4` | **2 / 256** | 4 |
| `vse16.v` (store) | `0x800002f0` | **2 / 256** | 4 |

**254 of 256 harts have their last retired instruction at `0x800002d8`** — `addi s10,s10,8`, the
instruction immediately before the first `vse16.v`:

```
800002d4:  vfmacc.vf  v0, ft7, v20     <- accepted, executed twice
800002d8:  addi       s10, s10, 8      <- LAST RETIRED, on 254/256 harts
800002dc:  slli       a2, a2, 1
800002e0:  add        a2, s5, a2
800002e4:  vse16.v    v0, (a2)         <- WEDGE
```

**Control:** in the fp32 kernel all **256/256** harts reach and pass `vse32.v` at the structurally
identical point, and the run completes at 97.6% FPU utilisation. Instruction retirement is
neck-and-neck up to the wedge (fp16 3,365 vs fp32 3,151 retired by cycle 12,238), so nothing is
merely slow — it is a hard stop at the first 16-bit vector store.

### ⚠️ Correction — what this evidence does and does not prove

An instruction appearing in the Snitch trace means Spatz **accepted** it, not that it **completed**.
So the table above proves the machine blocks with the first `vse16.v` unable to be *issued* — i.e.
Spatz's instruction queue is full — but it does **not** prove the store is the operation that fails
to complete. The queue could equally be full of earlier vector ops awaiting load data.

Two checks that were expected to discriminate, and did not:

| check | fp16 (hung) | fp32 (healthy) | verdict |
|---|---|---|---|
| stuck requests are reads or writes | 5,791, **all `R`** | — | reads dominate; the store is not visibly stuck |
| count of >1000-cycle stuck-read warnings | 5,791 | **31,496** | fp32 has *more* — not diagnostic |
| max stuck-read age | ~1,998 | ~1,977 | identical — no unbounded growth |

So "e16 stores wedge and e16 loads are fine" is **too strong**. What is solid:

1. 254/256 harts block at exactly the point where the next vector op is the first `vse16.v`; fp32
   passes the analogous point on 256/256 and completes at 97.6% FPU utilisation.
2. e16 loads take the burst path correctly — `[BURSTWHY]` reports **378/378 burst=1**, all five
   conjuncts passing at `vl=128B`, identical to fp32. The RTL change works as designed.
3. Harts `0x26`/`0x27` *did* accept all eight `vse16.v` stores and clear a request-sent
   `sfence.vma`, then parked on the barrier load at `0x80000294`. So the store path is not
   universally broken — which points at a **resource exhaustion / deadlock** that two cores beat.

Open question: which operation never completes. Note CLAUDE.md documents `group_mshr_num` as
"peak outstanding bursts — too small → sim deadlock", which is the right shape of failure for
"two cores got through, then everything blocked".

### Why every earlier hypothesis was on the wrong side

`use_port0_burst_req` requires `is_load` (`spatz_vlsu.sv:224`). **Stores never take the burst path
at all.** So the burst gate, its five conjuncts, 64-byte alignment, `SPATZ_VLSU_BURST_EW16`,
`flh`-vs-`flw`, and the MSHR read-coalescing story could never have explained a store hang. This
was derivable from the code hours before it was derived.

### Leading suspect

An e32 store presents a **full** byte strobe (`4'b1111`); an e16 store presents a **half** one
(`4'b0011` / `4'b1100`). A partial-strobe write may never have been exercised end to end in this
design. Checked by hand and *not* obviously wrong so far: strobe generation
(`spatz_vlsu.sv:1821-1833` — the single-element branch has a correct `EW_16` mask of 3; the generic
branch is byte-delta based) and `mem_counter_delta` (`:1249-1259`, all arms in bytes). Remaining
surfaces: the store VRF-read handshake at e16, the store commit/ROB path, and downstream
propagation of a partial strobe through tile → group → MSHR → bank (including whether anything
treats `strb` as a full-word qualifier, which would be a hang rather than corruption).

### Method note

The stuck PC came from the per-hart `trace_hart_0x*.dasm` files that a hung run leaves on disk —
no new simulation, no waveform, no GUI. Reading them should have been the *first* step; the whole
investigation reasoned about the memory system for hours without ever establishing where the
program actually was. GCC `objdump` cannot decode vector instructions and prints them as raw words
(`0x2065027`); use `install/llvm/bin/llvm-objdump -d --mattr=+m,+f,+d,+v,+zfh`.

---


## 2026-08-19 (late) — THE BURST PATH IS NOT THE VARIABLE; earlier sections are superseded

**The single decisive experiment.** Same 512x512x512 shape, same RTL, only the element width and
one knob differ. Knob value read out of each build's `compile.tcl`, not inferred from the
directory name:

| build | `SPATZ_VLSU_BURST_EW16` | workload | result |
|---|---|---|---|
| `build_fp32ref` | 0 | fp32 512³ | **healthy** — cyc 100,000, `bench`, 16/16 groups retiring, **97.6% FPU util** |
| `build_fp16nb` | **0** | fp16 512³ | **HANG** at 71,000 — 0/16 groups retiring, `raw` pegged |
| `build_fp16b` | **1** | fp16 512³ | **HANG** at 102,000 — same signature |

With the knob at 0, e16 loads take the **original legacy multi-port word-interleaved path** — the
code exactly as it was before any burst work. It still hangs. Therefore the burst gate, its five
`use_port0_burst_req` conjuncts (`spatz_vlsu.sv:223-234`), and 64-byte base alignment are all
**irrelevant to this hang**, and the `spatz_vlsu_burst_ew16` change is not implicated.

This should have been the *first* experiment. Hours went into the burst gate before it was run.

### Retractions — two findings were instrument artifacts, not signal

Both came from the core-memory scoreboard (`[CMS FINAL]`) dump of the fp16 arm, and both are
**withdrawn**. The healthy fp32 control (from the >1000-cycle `[CMS WARN]` stream of a *running*
arm — a cleanly-finished run has nothing in flight at exit, so the end-of-run dump structurally
cannot serve as the control):

| reading | fp16 "evidence" | healthy fp32 control | verdict |
|---|---|---|---|
| every stuck entry has `burst_len=1` ⇒ bursts never engaged | 6,173 / 6,173 | **31,496 / 31,496** | artifact |
| 16 ROB entries share one address on the vector port ⇒ per-beat offset lost | 14.93 mean, max 16 | **15.61 mean, max 16** | artifact — this is just how a burst appears at the CMS tap |

Neither distinguishes fp16 from fp32. Also: the arm did not *hang*, it was **killed** by a real
assertion, so its `[CMS FINAL]` list is a snapshot at the moment of death, not a picture of a wedge.

### What actually survives

- **The hang.** All 16 groups at `ins=0` with `raw` pegged. In the 512³ arms it occurs **before the
  timed window opens** — no `[FPU] bench` line is ever printed.
- **A genuine RTL bug, probably a second one.** `mempool_group_mshr.sv:2223`
  `"MSHR clock gate dropped a resp_buf write: entry=1 slot=0"`, cycle 11,376. A `resp_buf` slot's
  next-state differs from its current value while `mshr_rb_en[e][b]` is low, so the write is
  silently dropped. **Do not silence this assertion** — it exists precisely to catch the
  stale-data failure it is reporting. It is likely *not* the hang: `build_fp16nb` hangs without it
  ever firing.
- **The scalar port is healthy** (1.00 entries/address, same as fp32), so `flh` vs `flw` is closed.
- **The software port is clean**: normalising types and diffing `main.c` and `kernel/sp-fmatmul.c`
  against the fp32 originals yields only type substitutions.

### Instrumentation fixed along the way

`[STALLG]` prints **one CSV field per group**. A reader that parses only field 0 reports a healthy
run as hung — group 0 is legitimately 0 in many periods. This produced a wrong "the GVSOC
deliverable run is hung" call. Use `hardware/scripts/stallg_state.sh`, which sums all groups,
strips QuestaSim's leading `# `, and separates `HUNG` (0/16 retiring **and** `raw>0`) from
`IDLE/pre-trace` (0/16 with `raw==0`, i.e. tracing simply not enabled yet).

### Next

1. **Fast repro built** — `hardware/matmul_fp16_small.elf` (256x32x256, 142 KB vs 1.1 MB), so the
   loop is minutes rather than hours. Shape lives in `<app>/script/matmul.json`; the header must be
   regenerated manually with `python3 script/gen_data.py -c script/matmul.json` (the build does not
   do it).
2. **Localise the PC.** The whole investigation so far reasoned about the memory system without ever
   reading where the program is stuck. That is the gap.
3. Working hypothesis to test, not assume: this fork's VLSU additions (burst, ROB64,
   ParityDrain/TwinROB0 2-wide commit, H1 runahead) were all developed and validated at e32 only,
   and may have broken sub-word handling that upstream Spatz had working. Note `vl` is converted to
   **bytes** early (`spatz_vlsu.sv:187-201`), so any later code treating it as elements — or
   hardcoding a `>>2` word conversion — is a suspect.

---

## 2026-08-19 (earlier) — warm-up analysis (superseded by the knob-off experiment above)

### The warm-up is NOT the cause — the deadlock is in normal kernel operation

| variant | hang cycle | signature |
|---|---:|---|
| `ICACHE_WARMUP_N=6` (default) | 13,000 | `ins=0 raw=16000` |
| `ICACHE_WARMUP_N=8` (legal alternative) | **13,000** | `ins=0 raw=16000` |
| `ICACHE_WARMUP=0` (no warm-up at all) | **17,000** | `ins=0 raw=16000` |

Skipping the warm-up only DELAYS the wedge by ~4,000 cycles; the run reaches 86.2% FPU
utilisation and 64% cumulative, then dies anyway. Changing the warm-up's N to another legal
value does not even delay it. **Any "fix" that targets the warm-up is papering over the bug.**

### Warm-up N sweep: MEASURED, and it falsifies the stride-parity hypothesis

| ICACHE_WARMUP_N | A-row stride (words) | parity | hang cycle | reached benchmark? |
|---:|---:|---|---:|---|
| 6 (default) | 3 | **odd** | 13,000 | no |
| 8 | 4 | even | **13,000** | no |
| 16 | 8 | even | **13,000** | no |
| (warm-up disabled) | n/a | n/a | 17,000 | yes, 86.2% util |

An analysis had predicted that the "N must be EVEN" rule is written in ELEMENTS while the
property it protects is in 32-BIT WORDS -- so at fp16 the real requirement would be N = 0 (mod 4),
making 6 (= 2 mod 4) the worst legal choice and 8 the fix. **The measurement refutes it:** 8 and
16 both have even word strides and both deadlock at the identical cycle as 6.

The stride-parity observation is still a REAL latent contract bug worth fixing on its own merits
(see below), but it is NOT the cause of this deadlock.

**Three variants, three different signatures** -- which is itself a clue that the wedge is a
downstream consequence rather than a single deterministic fault:

| N | stuck reqs | fingerprint |
|---:|---:|---|
| 6 | 2,385 | `p=1 id=62/63`, address in `b` (vector burst port) |
| 8 | 4,876 | `p=0 id=0/1`, address in `a` (scalar port) |
| 16 | **0** | none at all |

### Genuine findings from the warm-up analysis (independent of the deadlock)

1. **`ICACHE_WARMUP_N` = 6 is the exact minimum for full I-cache coverage.** Verified against the
   disassembly: `matmul_8xVL` compiles to six basic blocks, and W=2 misses 340 bytes, W=4 misses
   118 bytes, W>=6 (even) covers every block the real N=64 run executes. The existing comment is
   correct and 8 is genuinely legal.
2. **ODD `ICACHE_WARMUP_N` is ILLEGAL and UNGUARDED.** The loop-exit test is `beq` against an
   even bound, so for odd W the break never fires and the loop exits via the back-edge with
   n = W+1, having loaded W+2 B rows -- reading up to 2 rows PAST `b`, which is immediately
   followed by `c` in memory. `main.c` guards only the REAL N (`gemm_l.N % 2`), so
   `-DICACHE_WARMUP_N=7` compiles and runs silently corrupt.
3. **The "even N" rule is element-based but protects a word-based property.** At fp32 the word
   stride IS N so "even" suffices; when `elem_t` halved the rule silently weakened by 2x. Worth
   restating in words, independently of this bug.
4. **`ICACHE_WARMUP_N` is invisible to sweep hygiene** -- it is a bare `#ifndef` in main.c, never
   emitted by `runtime.mk`, so a gate that diffs the emitted define set will not see it change.
   Pass it via `EXTRA_DEFINES` and delete the ELF first.

### The stuck fingerprint is IDENTICAL across every arm

```
WN8       p=1  hart=0xf8  id=62,63  age=1836  addr=0x00030a40   (inside b)
no-warmup p=1  hart=0x9f  id=62,63  age=1723  addr=0x000323c0   (inside b)
```

Different arms, different harts, different addresses — but **always port 1 (the VLSU burst
port), always ROB ids 62 AND 63, always a B-matrix address**. With `spatz_vlsu_rob_depth=64`
those are the last two entries of the ROB ring, and `spatz_vlsu_block_alloc=1` reserves a
16-id window in a single cycle. A burst allocated across the ring wrap is the boundary
condition that fits every observation: it needs thousands of cycles of drift to occur, it
produces the same fingerprint each time, and no single iteration is defective — which is why
static inspection of the kernel and the MSHR kept coming up empty.

### Everything else, eliminated with evidence

Eight+ knobs change nothing: the new burst-EW gate, `dual_load` (2 and 1 hang at the identical
cycle), `resp_wait_subs_single`, `enable_single`, `hold_window_burst`, `ICACHE_WARMUP`,
`ICACHE_WARMUP_N`, the group barrier, and the `vl`->bytes conversion. **Open test:** arm V
reverts the whole aggressive VLSU stack (`block_alloc=0`, `rob_depth=32`, `dual_load=1`) --
per the design docs that stack was developed and validated at e32 ONLY.

### Two instrumentation defects found and fixed (both cost hours)

1. **The tracer was blind to the warm-up.** Rows were gated on `csr_trace_any_global`, which
   software sets at `mempool_start_benchmark()`. The warm-up runs before that, so every arm
   that hung in the warm-up produced an EMPTY trace, and the only trace ever captured came from
   the `ICACHE_WARMUP=0` arm -- which was healthy at the time. Fixed: `+tracer_all`.
2. **The analyzer called healthy runs broken.** `META_MOD` hardcoded 32 (builds use 64),
   set-membership instead of difference arithmetic, a response COUNTER instead of distinct beat
   indices, and no awareness of the ParityDrain `core_id+(b&1)` retag (which surfaces as a
   change of `loc_p`, since the `core` column at the CORE taps is the tracer genvar). It
   reported 37-45% incomplete on a healthy fp32 arm. Fixed and validated to ~100% on fp32.

**Methodology lessons, both of which produced false root causes tonight:**
* Always run the KNOWN-GOOD arm through the same analysis. Every metric that looked damning for
  fp16 looked equally damning for a healthy fp32 run.
* Never conclude a knob is inert from periods where the mechanism is not yet exercised (ten
  byte-identical boot/DMA periods are not evidence).
* A cycle counter that has not advanced is not a hang: with the tracer on, 1,000 cycles took
  ~16 minutes, and a healthy arm was killed on a 90-second sample.

### Fast repro
`512x64x256` fp16, `hardware/matmul_fp16_512x64x256.elf`, wedge at cyc 13,000
(or `matmul_fp16_nowarmup.elf`, wedge at 17,000 -- that one is INSIDE the benchmark window and
is therefore traceable without `+tracer_all`).

---

# (historical) original notes below

2026-08-18. **Open bug.** Root cause NOT found. This records what has been eliminated (with
evidence) so the next person does not repeat it, and hands over the one correction that
invalidated part of the first analysis.

## Symptom

`sp-fmatmul-opt-burst-merge-fp16` deadlocks during the **icache warm-up pass** at every shape
tried so far (512x512x512 and 512x64x256 alike)
(before the timed region opens):

- every core stops retiring at cycle **12,000-18,000**; the sim runs on to 98,000 with
  `[STALLG] ins=0 raw=16000/16000` — a 100% RAW stall on every core
- `[CMS] inflight=2` (vs **9,921** in the healthy fp32 arm at the same point): the machine is
  *idle*, not thrashing
- stuck requests with monotonically growing `age`; cores are parked on
  `vfmacc.vf v0, ft7, v20`, waiting for a `vle16.v` that never lands
- the fp32 arm on the identical kernel structure is healthy and reaches its benchmark at 53,000

## What it is NOT (each with evidence)

| hypothesis | verdict | evidence |
|---|---|---|
| the new `spatz_vlsu_burst_ew16` gate | **NO** | arm B ran with `SPATZ_VLSU_BURST_EW16=0` (verified in its build log) and hung identically |
| `spatz_vlsu_dual_load` runahead | **NO** | dual_load 2 vs 1 on the same shape are **byte-identical at every period** (1447 / 4810 / 1044 / 433 …) and both deadlock at **exactly cyc=13000**. Not a timing coincidence to be explained away: the feature makes no difference whatsoever to this workload |
| group-barrier arrival mismatch | **NO** | `bar_rel=+16` (barriers firing) and `bar_max=40` (tiny spread) right up to the stall; the healthy fp32 arm reaches `bar_max=9664`. Barriers stopped because cores stopped *arriving* — downstream of the fault |
| `vl` -> bytes conversion for e16 | **NO** | `spatz_vlsu.sv:190` `EW_16: vl << 1` is correct (64 elements -> 128 B) |
| MSHR hold / subscriber config | **NO** | `[RH STUCK] subs=2/4` appears **more** often in the healthy fp32 arm (462 vs 128), and the MSHR defines are identical between the two builds |
| address misalignment | **NO** | `mem_is_addr_unaligned` is `rs1[1:0] != 0`; the stuck address `0xa1740` is even 64-B aligned |

## ⚠️ The correction that invalidated the first analysis

**`bl=1` in `[CMS WARN] STUCK_REQ` does NOT mean "this load never became a burst."**
`tb_core_mem_scoreboard.sv:281-308` *expands* a burst request of length N into **N separate
entries, one per expected beat id, each with `burst_len = 1`**. So `bl=1` is exactly what a
burst's individual beats look like in this probe.

Several deductions were built on the opposite reading — that the load had fallen off the port-0
burst path, hence that `use_port0_burst_req` must have failed its alignment test. All of that is
void. Check what a TB probe *records* before inferring hardware behaviour from it.

## Facts the root cause must explain

1. **It is the SCALAR path.** At the moment of the wedge the stuck requests are on **port 0 —
   the scalar port** — at addresses `0x000217e8` and `0x000217f4`, i.e. inside `a` and exactly
   **12 bytes apart = 6 fp16 elements = the warm-up's clamped N**. That is the `flh` walk down a
   column of A, `a__ += N`. Cores stall on `vfmacc.vf` because its *scalar* operand never returns,
   not because the vector load failed. (Vector-buffer addresses appear stuck too, but downstream.)

   **Leading hypothesis.** At fp32 every scalar FP load is a full 32-bit word. At fp16 `flh` is a
   **sub-word** load and two adjacent A elements share one word. The group MSHR admits singles
   into its merge pool (`group_mshr_enable_single=1`) and *holds* the response until
   `group_mshr_hold_subs_single=4` subscribers arrive (`group_mshr_resp_wait_subs_single=1`).
   Sub-word scalar requests are a case that path has never seen. Tests in flight:
   `group_mshr_enable_single=0` (singles bypass the MSHR entirely) and
   `group_mshr_resp_wait_subs_single=0` (deliver immediately, do not hold for subscribers).
2. **The stuck pattern differs by gate, as the request paths do.** Gate OFF: 426 distinct stuck
   addresses stepping individually (`0xa1500`, `0xa1510`, `0xa1520`, separate ids) — the
   word-interleaved multi-port path. Gate ON: many ids collapsed on one address — burst beats.
   Both deadlock.
3. **It is NOT shape-dependent — corrected 2026-08-18.** An earlier revision of this file claimed
   `512x64x256` ran clean; it does not, it deadlocks at ~12,000 cycles exactly like `512x512x512`.
   It was merely slower to arrive. **This is the useful correction**: a shape with an ideal of
   4,096 cycles reproduces the bug, so the repro is cheap and does not need the 2-hour full shape.
   Both shapes fail at ~12k, and both run the same warm-up (N clamped to 6, m range 0-8), so the
   trigger is in the warm-up rather than in the matmul dimensions.
4. **It fires in the warm-up pass**, where `ICACHE_WARMUP_N` clamps N to 6, so the A row stride is
   degenerate (6 elements = 12 B). The fp32 build survives the same clamp.

## Context worth knowing

The entire aggressive VLSU feature stack — `block_alloc`, ROB64, `dual_load`, and the burst path
itself — was designed and validated **at e32 only**. All three design docs
(`spatz_mlp_design_plan.md`, `spatz_rob64_h1_design_plan.md`, `tcdm_burst_interleave_design.md`)
mention `e16` **zero** times, and the ROB64 doc reasons explicitly in terms of "two e32,m2 loads =
2*32 ids exactly fill ROB0". The two other e16 apps in the tree (`gemv`, `gemv-bk`) have no built
binaries. The e16 VLSU path looks genuinely unexercised.

Note the ROB is an in-order **ring** (`read_pointer` / `write_pointer` / `status_cnt`), not a free
list, so an id "leak" is not possible — but a stall-forever is: if a burst reserves `BlockWords`
ids and fewer beats return, the ring can never advance past them.

## ⚠️ 2026-08-19 UPDATE — the "VLSU commit path" conclusion below is OVER-STATED

Two results after it was written:

**1. The exact-equality suspect is REFUTED.** A sim-only `[VLSU OVERSHOOT]` detector was added at
`spatz_vlsu.sv:632` and the repro re-run: the counter **never** passes `commit_counter_max`
(0 occurrences, arm OVS, hung at cyc=13000 as usual). `commit_finished` is not the blocker. The
counter simply never *reaches* max — commits stop partway — so the question is why they stop, not
how completion is tested.

**2. `inflight=0` was arm-specific and is probably a scoreboard artifact.** It held for H1
(`enable_single=0`) but NOT for the default config: arm OVS hangs with `inflight=5785` and 3,201
stuck requests. Worse, H1's own numbers are internally inconsistent (`req=74781 resp=63934` — a
10,847 gap — alongside `inflight=0`), so the CMS table is likely dropping or reusing entries
rather than reporting a genuinely idle memory system. **Do not treat `inflight` as authoritative.**

What survives from the section below: the MSHR knobs are all inert, and the stalled cores are
waiting on `vfmacc.vf v0, ft7, v20`. What does NOT survive: the confident claim that no memory
request is outstanding, and therefore the inference that the fault must be in the commit path.

**Solid facts, arm-independent:** cores RAW-stall at `vfmacc.vf` waiting for `v20`; stuck requests
are on **port 0 (scalar)** at addresses inside `a` stepping by the A row stride; two different
harts stall on the **same address with the same id and `beats=0`**; and eight independent
MSHR/VLSU knobs change nothing.

---

## (superseded) THE KEY FINDING: it is the VLSU COMMIT path, not the memory system

Arm H1 (`group_mshr_enable_single=0` + `resp_wait_subs_single=0` — scalar requests never enter
the MSHR at all) still deadlocks, one period later at cyc=14000. **But its signature is completely
different from the baseline:**

| | baseline | H1 (singles out of MSHR) |
|---|---:|---:|
| stuck requests | 2,385 | **0** |
| `[RH STUCK]` held entries | 174 | **0** |
| bank census | `hold=4 inv=0` (full) | — (none held) |
| **CMS `inflight` at the hang** | 2 | **0** |

**`inflight = 0`.** At the moment of the deadlock there is not a single outstanding memory
request — and yet every core is RAW-stalled (`raw=14962/16000`) at
`0x800002d4 = vfmacc.vf v0, ft7, v20`, waiting for `v20`.

If no memory operation is pending, the load's data has already come back. The VLSU is **not
committing it to the vector register file**, so the scoreboard keeps `v20` busy and the dependent
`vfmacc` never issues. That is a Spatz-internal stall in the load *commit* path, not a memory
system problem.

**This reinterprets everything earlier in this file.** The MSHR bank saturation (`hold=4, inv=0`)
and the 2,385 stuck requests in the baseline are a **downstream symptom**: cores stall -> their
loads never retire -> requests pile up -> banks fill. Remove singles from the MSHR and the symptom
disappears entirely while the deadlock survives. Do not chase the MSHR.

**Corollary — why every MSHR knob was inert.** `dual_load`, `resp_wait_subs_single` and
`enable_single` were all tested and none prevents the hang, which is exactly what you expect if
the fault is downstream of the memory system. `enable_single` is the only one that changes
anything at all (it removes the symptom and delays the hang by one period).

**⚠️ A methodology error worth not repeating.** H1 was byte-identical to the baseline for its
first ten periods, and that was read as "the knob is inert". It is not: the early periods are
boot and DMA, before the workload generates remote traffic, so *no* MSHR knob can differ there.
The divergence appears at cyc=11000 the moment real traffic starts. **Never conclude equivalence
from periods in which the mechanism under test is not yet exercised.**

## ⚠️ THE IN-TREE NoC TRACER IS UNRELIABLE FOR THIS DESIGN (found 2026-08-19)

`hardware/tb/tb_noc_req_resp_tracer.svh` + `hardware/scripts/analyze_noc_trace.py` stitch a
transaction using a "stable identity" of `(owner_group, owner_tile, core_id, meta_id)` at every
observation point. **That assumption is violated by ParityDrain.** With
`group_mshr_drain_beats=2`, beat `b` of a burst is delivered on tile response port `1+(b&1)`
with **`core_id+(b&1)`** — so odd beats arrive under a *different* core key and never attach to
the transaction that owns them.

Consequences, measured:

* The analyzer reports **42% of burst-16 reads "incomplete" on the HEALTHY fp32 arm**, which is
  running perfectly. Incompleteness in this tool is not evidence of a bug.
* Its `FROZEN transactions bucketed by LAST stage` table — the one headed "== the deadlock" —
  is likewise meaningless here: the healthy fp32 arm shows *more* frozen at `MSHR_REQ_IN`
  (5,123) than the deadlocked fp16 arm (3,132).

**Do not draw conclusions from this tool until it is retag-aware.** A naive fix (also try
`core_id-1` for odd beats) was attempted and is NOT correct either — it yields exactly 8/16 beats
for every transaction on both arms, so the retag is not a simple `+1` on the traced field. The
tracer taps and the ParityDrain retag need to be reconciled by reading
`mempool_group_mshr.sv`'s drain path before the analyzer can be trusted.

This is a real defect in the debug infrastructure and it cost most of a debugging session: two
candidate root causes ("incomplete bursts", "frozen at CORE_REQ") were derived from it and both
were artifacts, caught only by running the healthy fp32 arm as a control.

**Lesson: always run the known-good arm through the same analysis.** Every metric that looked
damning for fp16 looked equally damning for a healthy fp32 run.

## Next step: waveforms, now well-targeted

Log-level analysis is exhausted. The concrete next move is to take one stuck request and follow
it from issue to non-response:

The search is now narrow: **one core's VLSU, at the moment its load data returns.**

1. Fast repro: `512x64x256` fp16, `hardware/matmul_fp16_512x64x256.elf`, deadlock at cyc 13000-14000.
2. Re-run with logging scoped to ONE core's Spatz VLSU (the whole design is not needed).
3. Watch, for the load that fills `v20`: the ROB pop, `commit_counter_*`, the VRF write-enable, and
   the instruction-retire/scoreboard-release signal. The data returns (`inflight=0`); the question
   is which of those never fires at `vsew = EW_16`.
4. **PRIME SUSPECT — an exact-equality completion test.** `spatz_vlsu.sv:632`:

   ```systemverilog
   assign commit_finished_q[fu] = commit_insn_valid && (commit_counter_q[fu] == commit_counter_max[fu]);
   ```

   `==`, not `>=`. If a commit ever advances the counter **past** max, this never matches, the
   load never completes, `mem_finish_ready` (`:818`) never asserts, and the destination vector
   register is never released — a permanent stall with the data already returned and nothing
   outstanding. **That is exactly the measured signature.**

   The commit delta is element-size dependent —
   `commit_single_element_size = 1 << commit_insn_q.vsew` (2 B at e16) versus `ELENB` (4 B) for
   the full-word path (`:1064-1066`) — and `switch_to_tail_phase` re-bases the counter mid
   instruction (`:1070`). An overshoot at e16 is plausible there and is invisible at e32, where
   element size and word size coincide so every delta divides `max` evenly.

   **To confirm:** log `commit_counter_q[fu]`, `commit_counter_max[fu]` and `commit_counter_delta[fu]`
   for the stalled core and look for `q > max`. If confirmed, the minimal fix is `>=` (with a
   width check), but the *correct* fix is to stop the overshoot at source.

## Status of the surrounding work

The RTL change this was meant to exercise is **independently proven safe**: the same fp32 ELF run
with `spatz_vlsu_burst_ew16` 0 vs 1 is byte-identical over 280+ probe-periods across five counters
(`scripts/check_arm_equivalence.py`), both arms opening the timed region at exactly cyc=53000. The
deadlock does not implicate it and does not block landing it.
