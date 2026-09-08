# Group-MSHR pipeline cuts: request and response

Planning document for closing `mempool_group_mshr` below 2 ns. All numbers are measured from the
out-of-context `initial_opto` runs on commit `51afaf8c` (`chain_2p0` / `chain_1p2` / `chain_1p0`),
TSMC N7, `ssgnp_0p675v_m40c`, POCV, `cworst_CCworst_T`.

## 1. Where we are

| TCK | WNS | TNS | violating endpoints | cell area | instances |
|---|---:|---:|---:|---:|---:|
| 2.0 ns | **-0.000086** | -0.000 | **1** | **117,622 um^2** | 1,159,531 |
| 1.2 ns | -0.396 | -1,885 | 14,614 | 153,293 um^2 | 1,357,138 |
| 1.0 ns | -0.652 | -6,161 | 20,727 | 156,390 um^2 | 1,354,801 |

2 ns closes. 1.25 ns (the 800 MHz target) does not.

Note the area column: tightening the clock from 2.0 to 1.2 ns costs **+35,671 um^2** of upsizing and
still misses. Any pipeline stage that relieves that pressure pays for its own flops many times over.

## 2. Two disjoint violating cones, not one

The top-20 path list is 20-of-20 `group_mshr_req_i -> clock_gate_mshr_q_valid_reg_*`, but that is
the worst *tail*, not the population. Classified by endpoint at 1.2 ns:

| cone | endpoints | worst slack | TNS share |
|---|---:|---:|---:|
| A -- request: `group_mshr_req_i` -> `clock_gate_mshr_q_valid_reg_*` | 5,488 | **-0.395** | -850 (45%) |
| B -- response: capture -> `mshr_q_reg.resp_buf.*` | 9,126 | -0.361 | **-1,035 (55%)** |

Cone B's core is exact: **8,192 endpoints = 64 entries x RespBufWords(4) x 32 bits** -- *every*
response-buffer data bit is violating.

**One cut fixes one cone.** A request-side cut alone leaves ~55% of TNS. Closing 1.2 ns needs both.

(Caveat: multibit flops merge 6-8 unrelated bits into one cell, so the A/B split by endpoint name is
approximate for mixed cells. The 8,192 pure `resp_buf.data` bits are unambiguous.)

## 3. Existing staging -- check this before adding anything

| instance | parameter | state in the PnR build |
|---|---|---|
| `i_spill_req_in` | `SpillReqIn` (knob, RTL default 1) | **0 -- BYPASSED** |
| `i_spill_req_out` | `SpillReqOut = 1'b1` | registered |
| `i_spill_resp_in` | `SpillRespIn = 1'b1` | **already registered** |
| `i_spill_resp_out` | `SpillRespOut = 1'b1` | registered |

Two consequences:

* The request input is **raw combinational** into `i_req_decode`. `GROUP_MSHR_SPILL_REQ_IN=0` is set
  in both the sim and the PnR define sets, so the RTL default of 1 is being overridden off.
* The response input is **already a flop**, so cone B's paths are reg-to-reg. "Register the response
  input" is not available -- a response cut has to go *inside* the capture chain.

## 4. Step 0 (free): turn `SpillReqIn` back on

Zero new RTL. `spill_register` is a proper 2-deep elastic buffer, so the handshake stays correct and
there is no bandwidth loss.

Measured worst path today (100 cells, arrival 1.542 ns against 1.146 required):

| segment | delay | cells |
|---|---:|---:|
| input external delay + port | 0.309 | -- |
| `i_req_decode` | 0.071 | 4 |
| top: decode -> arbiter | 0.449 | 38 |
| `i_alloc_arb` | 0.127 | 9 |
| top: arbiter -> clock gate | 0.586 | 49 |
| **logic total** | **1.233** | **100** |

Replacing the 0.309 ns input arrival with a 0.172 ns clock-to-Q buys ~0.137 ns: WNS -0.395 -> ~-0.26.
Useful, not sufficient. Much of the 0.300 ns is an OOC artifact (`set_input_delay`); in the real
block the driver is an adjacent module, so the standalone gain overstates the in-context gain.

## 5. Cut R -- request path, at the allocation/merge arbiter output

Split the 1.233 ns / 100 cells at the `agb_*` / `mgb_*` arbiter outputs:

| stage | logic | cells | with clk-to-Q | vs 1.146 (1.2 ns) | vs 0.947 (1.0 ns) |
|---|---:|---:|---:|---|---|
| R1: req flop -> arbiter out | 0.647 | 51 | 0.819 | **PASS** (+0.33) | **PASS** (+0.13) |
| R2: arb flop -> clock gate | 0.586 | 49 | 0.758 | **PASS** (+0.39) | **PASS** (+0.19) |

Near-perfectly balanced, and **cone A would meet even 1.0 ns**.

### State crossing the cut (MshrBankNum = 16)

| group | fields | bits/bank | x16 |
|---|---|---:|---:|
| `agb_*` | `v`(1) `way`(2) `addr`(16) `grp`(4) `len`(5) `tile`(4) `port`(2) `core`(2) `meta`(6) | 42 | 672 |
| `mgb_*` | `v`(1) `way`(2) `tile`(4) `port`(2) `core`(2) `meta`(6) | 17 | 272 |
| **total** | | **59** | **944 flops** |

### The real cost is the interlock, not the flops

The entry array is written a cycle later, so within that cycle:

1. **Way reuse.** The allocator must not grant the same way twice. Needs a per-bank in-flight
   reservation (`valid` + `way`, 16 x 3 = 48 bits) that `bank_has_free` / `bank_free_id` exclude.
2. **Same-address hazard.** Two requests to the same line in consecutive cycles would each miss and
   allocate separate entries, because the first is not yet in `mshr_q`. `req_addr_hit_way` must also
   compare against the in-flight `agb_addr` / `agb_grp`.
3. **Response race.** `no_alloc_while_resp_landing` currently holds by construction; with a deferred
   write it must be re-proved or re-asserted.

Item 2 is the one that matters -- it is the same class of defect as the bug fixed in `137366b8`,
where a one-cycle vintage skew between two readers of the entry array deadlocked 5 of 8 shapes.

## 6. Cut S -- response path, inside the capture chain

`resp_in` is already registered, so the violating chain is entirely internal:

```
resp_in[t][p] (32 lanes, flop)
  -> tag decode        rsn_v / resp_is_mshr : mshr_tag-1, mshr_q_valid, state, burst_beat_valid
  -> per-bank arb      capb_l1/l2, capb_g1/g2 vs mshr_resp_slots
  -> scatter           cap_first / cap_second / cap_g1 / cap_g2   (per entry)
  -> data mux          cap_d0[e] / cap_d1[e]   -- 32 lanes -> 64 entries, 32 bits wide
  -> write             mshr_d[e].resp_buf[cap_s0/s1], mshr_rb_we -> mshr_rb_en (clock-gate enable)
```

The expensive element is the **32-lane -> 64-entry, 32-bit-wide data crossbar** feeding `cap_d0`,
plus the `mshr_rb_en` clock-gate enable, which is a gating check and therefore ~0.175 ns tighter
than a D-pin check.

**Proposed cut: after the grant, before the data mux.** Register per lane the decoded entry id, the
beat offset, the grant bit and the payload; the next stage does the scatter, the mux and the write.

| crossing | width | x32 lanes |
|---|---:|---:|
| payload `data` | 32 | 1,024 |
| decoded `mshr_id` | 6 | 192 |
| `beat_off` | 4 | 128 |
| grant / valid | 1 | 32 |
| **total** | **43** | **~1,376 flops** |

The alternative -- cutting *after* the mux, per entry -- is worse: 64 entries x (32 data + slot + we)
x 2 grants is ~4,600 flops.

**Delay split: NOT YET MEASURED.** `critical_paths.rpt` holds only the 20 request paths, so cone B
has no cell-by-cell breakdown yet. A `report_timing -to *resp_buf*data*` probe on the saved
`ooc_chain_1p2/initial_opto` block is in flight. **Do not commit to cut S's placement before that
lands** -- the split above is structural reasoning, not measurement.

## 7. Cost summary

| item | cost |
|---|---|
| Cut R flops | ~944 + ~48 reservation |
| Cut S flops | ~1,376 (estimate) |
| **total** | **~2,370 flops, ~0.17% of 1.36M instances** |
| area | likely **net negative** -- 35,671 um^2 of upsizing avoided between 1.2 and 2.0 ns |
| latency | +1 cycle request admission, +1 cycle response capture => +2 cycles per miss round trip |
| bandwidth | none, if both cuts keep proper valid/ready elasticity |
| risk | the cut-R interlocks (section 5); cut S must not reintroduce vintage skew |

The latency cost is the one to measure, not assume. The MSHR sits on the remote-load path, and
+2 cycles per miss round trip is a throughput question for the GEMM kernels, not a free win.

## 8. Order of work

1. **Step 0** -- `GROUP_MSHR_SPILL_REQ_IN=1`, re-run OOC at 1.2 ns. Free, and calibrates how much of
   the 0.300 ns input delay is real.
2. **Measure cone B** -- finish the `resp_buf` path probe; place cut S on data, not on the sketch above.
3. **Cut R** with its interlocks, then the full 8-shape bit-exact sweep before any OOC.
4. **Cut S**, same discipline.
5. Re-run 2.0 / 1.25 / 1.0 ns and re-derive the table in section 1.

Every step gets the validation that `137366b8` got: 8 shapes, cycle counts bit-exact against the
reference, `STUCK_REQ` counts matching. A functional regression here costs days and hides behind
assertions that do not cover the case -- `no_late_join_burst` was gated on `req_len > 1` and missed a
deadlock for two days.
