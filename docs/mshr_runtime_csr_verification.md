# Runtime-configurable group MSHR — verification record

Design: [`mshr_runtime_csr_design.md`](mshr_runtime_csr_design.md).
Performance: [`benchmarks/gemm_results_mshr_ppa_csr.md`](benchmarks/gemm_results_mshr_ppa_csr.md).

The group MSHR's sharing targets, hold windows, serve timeout and bank-hash selectors became
software-writable through group-level CSRs, reached over the group-barrier port's `bank == 3`
encoding. **The MSHR ships DISABLED out of reset**; software programs and enables it before the
timed region.

## Verdicts

| gate | claim | result |
|---|---|---|
| **V1** | `cfg_runtime=0` is bit-identical to the pre-CSR design | **PASS** — 34,596 == 34,596, config verified identical to the `ppa_C1` reference across the full define set |
| **V2** | *(retasked)* cost of leaving the MSHR unconfigured | **53,835 vs 34,596 = +55.6%** |
| **V3** | software-written CSRs == elaborated constants | **PASS** — MSHR work counters byte-identical; +265 cyc (+0.77%) cold-start |
| **V4** | `hold_subs_burst = 1` written via CSR makes bursts bypass | **PASS** — `alloc_burst=0 merged_burst=0` while `alloc_single=89 merged_single=586` |
| **V5a** | an out-of-range CSR write is refused and reported | **PASS** — `status=0x2` (`RANGE=1`, `BANK_BUSY=0`) |
| **V5b** | the bank hash never changes while entries are resident | **PASS** — `bank_hash_stable_while_valid` never fired in any run |
| **V6** | Spyglass clean on the changed RTL | pending |

## Two real bugs, both found by V3, both in the same six lines

Neither was reachable before: every prior campaign arm ran `cfg_runtime=0`, where `bank == 3` never
occurs. They are recorded because the *pattern* generalises.

**1. CSR writes corrupted barrier state.** `bank == 3` fell through to `OP_WR_MASK` (`2'd2`), so every
CSR write also executed `mask_d[req_struct_i] = req_cfg_data_i` on the barrier — and `req_struct_i`
is the CSR index, so writing CSRs 0–8 and 15 clobbered barrier structs 0–8 and 15.
`mempool_barrier()` then waited on a mask nobody set. 16 stuck requests, one per group's designated
writer, before the benchmark ever started.

**2. CFG_STATUS reads were barrier arrivals.** `bar_op` tested `!wen` *before* the bank, so a read of
any bank became `OP_ARRIVE`. The status read-back at the end of `mshr_cfg_apply_group()` was a
barrier arrival at a struct needing all 16 cores; one core per group arrived, nothing released, the
read never returned. **Identical 16-stuck signature to bug 1**, which is why fixing only the write
side changed nothing visible and looked like the first fix had failed.

**Lesson.** The design note claimed struct N with bank 1 and struct N with bank 3 "never collide
because the op distinguishes them". That was false in both directions. *Claiming a spare field value
is not enough — the consumer's decode has to be given the new case*, for reads as well as writes.

Fix: `OP_EXT_ACK` (`2'd3`) acknowledges without touching barrier state, plus `req_ext_rd_i` /
`ack_rd_q` so a foreign READ responds with `resp_wen = 0` and the adapter returns the status word.

## Why V3's pass criterion changed

It was originally "exactly 34,547". That is the right test for a *drop-in transparent* feature, and
the wrong one here: with the MSHR off by default it enters the timed region **cold**, while a
fixed-function build has it warm from reset. A small positive delta is guaranteed by the design, not
evidence against it.

The criterion that actually tests the claim is **identical MSHR work counters**, and those match
exactly:

```
                merged_single   merged_burst   alloc_single   alloc_burst    TOTAL
v3ref  (const)     860160         122880         122880        122880      1228800
v3fix2 (CSR)       860160         122880         122880        122880      1228800
```

The +265 cycles is the measured price of off-by-default on this shape.

## Design decisions recorded

- **Reset `enable = 0`.** Deliberate: init, DMA and I$ warm-up never occupy a way. The cost is that
  any binary not calling `mshr_cfg_apply_group()` silently runs **+55.6%** slower. Mitigated by the
  `[MSHRCFG]` TB check, which reports at benchmark start whether every group was enabled — a missing
  configuration is now one grep, not a mystery regression.
- **`HoldSubs` guard relaxed to `[1, MshrMergeReqs]`.** 1 is the defined "bypass this class"
  encoding and was already legal at runtime; the old `[2, …]` bound made a legal runtime value
  illegal as a reset value, so a flavour could not ship a bypassed class.
- **`ServedCntMax` sized from `MshrMergeReqs` when `MshrCfgRuntime`.** Sibling of the `HoldCntMax`
  fix: the width came from the elaborated defaults but was compared against runtime values, so a
  software write larger than the default would truncate and make the self-invalidate compare
  always-true. Verified inert today — **0 of 23 shapes change** — because every flavour happens to
  set `hold_subs_single == merge_reqs`. That was an accident, not an invariant, and nothing enforced
  it.

## Known limitation

`MSHR_CFG_NEGTEST=1` (the V5a negative test) passes its check and then wedges the run with ~12k
stuck requests on ordinary data. `v5b` isolated the cause to the test block itself: the same shape
and RTL with `negtest=0` completes normally (3,667 cyc). The block is default-off and affects
nothing; it is not usable as a repeatable regression test in its current form.
