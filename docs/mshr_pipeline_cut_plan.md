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

## 2. One cone, not two -- 98.3% of violating paths start at the request port

Classified over a **3,000-path** population sample (`report_timing -max_paths 3000 -path_type short`
on the saved `chain_1p2/initial_opto` block), cross-tabulating startpoint against endpoint family:

| startpoint | paths | endpoints reached |
|---|---:|---|
| **`group_mshr_req_i`** | **2,949 (98.3%)** | other 2,271 - `resp_buf.*` 616 - `resp_buf.data` 55 - `clock_gate` 7 |
| internal flops | 51 (1.7%) | other 51 |

The request port feeds **every** endpoint family, including the 8,192-bit `resp_buf.data` group
(64 entries x RespBufWords(4) x 32 bits, all violating). That family is *not* response-fed: the
store byte-merge at `mempool_group_mshr.sv:2463` writes
`mshr_d[e].resp_buf[rd_ptr].data[b*8 +: 8]` straight from the request path. Measured worst path into
it, 90 cells, arrival 1.690 ns:

| segment | delay | cells |
|---|---:|---:|
| input external delay + port | 0.309 | -- |
| `i_req_decode` | 0.061 | 5 |
| top: decode -> arbiter | 0.480 | 30 |
| `i_alloc_arb` | 0.120 | 13 |
| top: arbiter -> `resp_buf.data` D-pin | **0.720** | 42 |
| **logic total** | **1.381** | **90** |

Same structure as the `clock_gate` path, and **through the same `i_alloc_arb`**.

> **Correction.** An earlier revision of this document claimed two disjoint cones -- a request cone
> and a response cone -- and concluded that two cuts were required. That was wrong. It classified
> 14,614 endpoints by *name* and assumed `resp_buf.*` implied a response-side source. Endpoint names
> say where a path ends, never where it starts. The 20-path `critical_paths.rpt` was too small a
> sample to notice; the 3,000-path population settles it. **One cut suffices.**

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
| R2': arb flop -> `resp_buf.data` | **0.720** | 42 | 0.892 | **PASS** (+0.25) | **PASS** (+0.06) |

R2' is the tightest of the three and still fits, narrowly, even at 1.0 ns. One cut covers
98.3% of violating paths.

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

## 6. Cut S -- NOT REQUIRED

An earlier revision planned a second cut inside the response capture chain, on the assumption that
the `resp_buf.*` endpoints were response-fed. Section 2 shows they are request-fed through the store
byte-merge, and the measured post-cut stage R2' below covers them. **Cut S is dropped**, saving
~1,376 flops and a whole design step.

For the record, `resp_in` is already registered (`SpillRespIn = 1'b1`), so a response-side cut would
have had to go inside the capture chain in any case, and only 1.7% of violating paths start at an
internal flop at all.

## 7. Cost summary

| item | cost |
|---|---|
| Cut R flops | ~944 + ~48 reservation |
| Cut S flops | **not required -- see section 6** |
| **total** | **~992 flops, ~0.07% of 1.36M instances** |
| area | likely **net negative** -- 35,671 um^2 of upsizing avoided between 1.2 and 2.0 ns |
| latency | +1 cycle request admission (response capture untouched) |
| bandwidth | none, if both cuts keep proper valid/ready elasticity |
| risk | the cut-R interlocks (section 5); cut S must not reintroduce vintage skew |

The latency cost is the one to measure, not assume. The MSHR sits on the remote-load path, and
+1 cycle on request admission is a throughput question for the GEMM kernels, not a free win.

## 8. Order of work

1. **Step 0** -- `GROUP_MSHR_SPILL_REQ_IN=1`, re-run OOC at 1.2 ns. Free, and calibrates how much of
   the 0.300 ns input delay is real.
2. **Cut R** with its interlocks (section 5), then the full 8-shape bit-exact sweep before any OOC.
3. Re-run 2.0 / 1.25 / 1.0 ns and re-derive the table in section 1.
4. Only if 1.25 ns still misses, re-profile the population -- do not assume where the next cone is.

Every step gets the validation that `137366b8` got: 8 shapes, cycle counts bit-exact against the
reference, `STUCK_REQ` counts matching. A functional regression here costs days and hides behind
assertions that do not cover the case -- `no_late_join_burst` was gated on `req_len > 1` and missed a
deadlock for two days.
