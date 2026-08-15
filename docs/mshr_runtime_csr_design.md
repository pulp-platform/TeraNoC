# Runtime-configurable group MSHR — hardware + software design

| | |
|---|---|
| Date | 2026-08-15 |
| Status | Design, not yet implemented |
| Target | `terapool_spatz4_fpu_backend_4x4`, 256 cores / 16 groups |
| Motivation | Today every knob comparison costs a rebuild plus a 23-arm sweep. That is what consumed 2026-08-14 end to end. Runtime configuration collapses a sweep-per-config into configs-per-simulation. |

## What this buys, in priority order

1. **Experiment turnaround.** The opt3 bisect, hold-window curves and `hold_subs` sensitivity
   studies become minutes instead of hours. For a design still carrying an unexplained
   order-of-magnitude regression in its default configuration, this is worth more than any single
   knob below.
2. **A correct-by-construction config for B-share=1 shapes** (rule R3), removing the per-shape
   `hold_window_burst := 0` pin that a launcher bug already defeated once.
3. **Keeping init/warm-up traffic out of the MSHR**, so ways and the response cache are not occupied
   during a phase whose locality does not matter.

## What it does NOT solve — stated up front

The open `bank_publish=1` collapse (`128x128x512` +1,160%, `128x1024x512` +84%, both at
`hold_window_burst=0`) is **not** a hold/merge problem and none of these CSRs address it. They make
it far cheaper to *bisect*, which is the actual next step. Do not let this work be justified as a fix
for that.

Likewise there is **no M=128 utilisation problem at the shipping config** — those shapes are the best
in the table (96.8 / 95.0 / 90.6 / 83.7%). The low utilisation only appears when the window pin is
overridden. R3 makes that unbreakable; it does not raise the ceiling.

---

# Hardware

## 1. Address map — no new address space needed

The group barrier already provides a decoded, group-level, software-writable port, and its op field
has a free encoding. From `mempool_group.sv:475-486`:

```systemverilog
bar_word   = tgt_addr[TCDMAddrMemWidth + BankW - 1 : BankW];   // word field
bar_bank   = tgt_addr[BankW-1 : 0];                            // bank field = op
bar_struct = bar_word - GroupBarrierWord;                      // which barrier struct
bar_op     = (!wen) ? 0 : (bar_bank == 1) ? 1 : 2;             // 0=ARRIVE 1=WR_TARGET 2=WR_MASK
```

`BankW = idx_width(NumBanksPerTile) = 2` at this config, so `bar_bank` takes 0..3. Writes with
bank 1 mean WR_TARGET, bank 2 means WR_MASK (documented), and **bank 3 is unused** — it currently
falls into the `else` and aliases onto WR_MASK.

**Take bank 3 as the MSHR-CSR write op, and reuse `bar_struct` as the CSR index.**

| field | source | meaning |
|---|---|---|
| `bank == 3` and `wen` | `tgt_addr[1:0]` | op = MSHR_CSR_WRITE |
| `bar_struct` (4b) | `word - GroupBarrierWord` | which CSR, 0..15 |
| write data (16b) | `req_cfg_data_i` | the value |

That is **16 CSRs x 16 bits with zero new address space and zero new crossbar decode**. `bar_op`
widens from 2 to 3 bits; struct N with bank 1 (barrier target) and struct N with bank 3 (CSR N)
never collide because the op distinguishes them.

Byte address software must form:

```
(word << WORD_STRIDE_SHIFT) | (target_tile << 6) | (3 << 2)
word = GROUP_BARRIER_WORD + csr_index
```

⚠️ **`WORD_STRIDE_SHIFT` must be DERIVED, never hardcoded.** It is 14 at 16 groups and 16 at 64.
A hardcoded `<<14` in `sp-fmatmul.c` made the group barrier a silent no-op across the entire 8x8
campaign. Use `4 * BANKS_PER_TILE * NUM_TILES_PER_GROUP * NUM_GROUPS`, as `arch.ld.c` and
`gbar_base()` already do.

## 2. The CSR file

New module `mempool_group_mshr_cfg.sv`, instantiated in `mempool_group.sv` beside the barrier,
fed by the same decoded request. One flop bank per group.

| idx | CSR | bits | reset | notes |
|---:|---|---:|---|---|
| 0 | `CFG_ENABLE` | 1 | **0** | 0 = all requests bypass the MSHR. Default OFF per the proposal: init and warm-up never allocate. |
| 1 | `CFG_HOLD_SUBS_SINGLE` | 3 | elaborated `HoldSubsSingle` | 1 = this class bypasses (rule R3) |
| 2 | `CFG_HOLD_SUBS_BURST` | 3 | elaborated `HoldSubsBurst` | 1 = this class bypasses |
| 3 | `CFG_HOLD_WINDOW_SINGLE` | 11 | elaborated | clamped to `HoldWindowHwMax` |
| 4 | `CFG_HOLD_WINDOW_BURST` | 11 | elaborated | clamped |
| 8 | `CFG_SERVE_TIMEOUT` | 11 | elaborated `ServeTimeout` | **response-side, SINGLE-request only** — never arms for bursts. See below. |
| 5 | `CFG_BANK_SHIFT_SINGLE` | 3 | elaborated | encoded, see §4 |
| 6 | `CFG_BANK_SHIFT_BURST` | 2 | elaborated | encoded |
| 7 | `CFG_BANK_BURST_BITS` | 1 | elaborated | encoded |
| 15 | `CFG_STATUS` (RO) | 16 | — | sticky error bits, §5 |

### `hold_window_*` vs `serve_timeout` — different mechanisms, one counter

These are easy to conflate and were conflated once already, at real cost: the four B-share=1 shapes
inherited `serve_timeout = 2047` while `gemm_results.md` was measured at 255, and the resulting
two-variable comparison read as a fake +34%/+41% RTL regression.

| | `hold_window_single/burst` | `serve_timeout` |
|---|---|---|
| side | **request** | **response** |
| live state | `WAIT_RESP && !issued` | `RESP_HOLD`, and `CACHED` below target |
| on expiry | issue the withheld NoC fetch | `RESP_HOLD` -> deliver to whoever is present (`:3393`); `CACHED` -> self-invalidate and free the way (`:4051`) |
| per-type | yes (single / burst) | one value, but **single-only in effect** |
| applies to bursts? | yes, `hold_window_burst` | **NO** — both arming sites are guarded on `burst_len == 1` (`:3390`, `:4037`) |
| CSR | idx 3 / idx 4 | **idx 8** |

They share the physical `hold_cnt` field because the request-side hold lives only in
`WAIT_RESP && !issued`, which is mutually exclusive with both response-side states (`:232-234`).
So the CSR pair costs no extra storage — but the counter width must cover **both**:

```
HoldCntMax = max(HoldWindowHwMax, ServeTimeoutHwMax)     // = 2047 with both bounded at 2047
```

**`serve_timeout` never arms for burst entries.** Both sites that load it are explicitly gated:

```systemverilog
:3390  RespWaitSubsSingle && burst_len == 1 && sub_reqs_num < HoldSubsSingle  -> RESP_HOLD
:4037  EnableRespCache && cacheable && burst_len == 1                        -> CACHED
```

A burst entry can enter neither state, so the timeout is a **single-request** backstop despite its
general-sounding name. This matters for reading the 2026-08-14 confound correctly: on the four
B-share=1 shapes it is the **A traffic** (16-way-shared single-word loads, `hold_subs_single = 16`)
that sits in `RESP_HOLD` waiting for subscribers, and `serve_timeout` decides when it gives up. The
B bursts are unaffected by it — their cost came from `hold_window_burst`, a different knob on the
request side.

Consider renaming to `serve_timeout_single` when this lands, or at minimum documenting it at the
parameter (`:228-236` describes the states but not that both are single-only).

**Two constraints the CSR file must enforce**, because software can otherwise write a configuration
the hardware forbids at elaboration:

1. `ServeTimeout == 0` is illegal when `RespWaitSubsSingle || !CacheReclaimable` — there is an
   elaboration `$error` at `:328`. A runtime write of 0 under those conditions must be **rejected**
   and set the `CFG_STATUS` sticky bit, not silently accepted. Without the timeout an entry whose
   serve target is never reached pins its way forever.
2. Neither value may exceed its hardware bound; clamp and flag rather than truncate silently.

**Every reset value is the value that config elaborates today.** An unconfigured run must be
bit-identical to the current design — that is the first verification gate (§V1).

## 3. MSHR changes: `localparam` -> input port

`mempool_group_mshr.sv` gains one input `mshr_cfg_t cfg_i`, and each runtime knob changes from a
`localparam` read to a signal read. The consumption sites are shallow:

| knob | today | change |
|---|---|---|
| `HoldSubsSingle/Burst` | compare operand, `:1406` etc. | read `cfg_i.*` instead — a compare, not a structure |
| `HoldWindow*` | `hold_cnt` reload constant | reload from `cfg_i.*` |
| `BankSelShift*`, `BankBurstBits` | constant part-select in `mshr_bank_of` (`:456`) | small mux, §4 |

**One structural dependency the obvious plan misses.** `HoldSubs*` also *sizes* `ServedCntW` through
`ServedCntMax` (`:358`). Runtime means sizing for `MshrMergeReqs`, not the configured value:

| merge_reqs | hold_subs | `ServedCntW` now | runtime | cost |
|---:|---:|---:|---:|---|
| 4 | 4 | 3b | 3b | 0 |
| 8 | 8 | 4b | 4b | 0 |
| 16 | 2 | 2b | 5b | **+3b x 64 = 192 flops/group** |

Small, but it must be in the plan or the first `merge_reqs=16` build changes area unexpectedly.

**What stays elaboration-time**, because it sizes arrays and structures, not comparisons:
`MshrNum`, `MshrWaysPerBank`, `MshrMergeReqs`, `RespBufWords`, `DrainBeats`.

## 4. Bank hash: field-wise encoding, not a hash table

Across all 24 benchmarked shapes there are **17 distinct `(shift_single, shift_burst, burst_bits)`
triples** — too many for a small lookup table. But the fields vary independently and each has a tiny
range:

| field | observed values | bits |
|---|---|---:|
| `shift_single` | 5,6,7,8,9,10 | 3 |
| `shift_burst` | 5,6,7 | 2 |
| `burst_bits` | 0,1 | 1 |

**6 bits total covers every benchmarked shape exactly**, and unlike a 17-entry table it also covers
shapes nobody has benchmarked. Store the fields; do not build a table.

Cost: `BankIdW = 4`, so a 6-way select is `4 x 6:1 ~ 20 mux2`, plus 8 for the burst side — about
**28 mux2 per `mshr_bank_of` instance**. That function is called in the per-(tile,port) request loop
(`:1648`), so 32 instances = **~900 mux2/group, ~1k GE/group, ~28k GE cluster**. Negligible against
the ~228k flops the entry array already costs.

The residual concern is **timing, not area**: this sits on the `req_in_ready` path that C2 made
combinational to the tile and that the backend review estimates at ~30-40 levels. One mux level is
unlikely to decide closure, but check the post-placement report rather than the gate count.

## 5. Semantics and safety — the part that will bite if skipped

**R3: `hold_subs_* == 1` means "this class does not merge — bypass".** Today `< 2` is an elaboration
`$error` (`:317-318`), which is why the auto-tuner clamps 1 up to 2 and creates the trap. Redefining
1 makes the illegal value the correct behaviour. Replace the `$error` with a legal-range check of
`[1, MshrMergeReqs]`.

**Change-time safety differs per CSR, and one of them is a correctness hazard:**

| CSR | safe to change while entries are resident? |
|---|---|
| `CFG_ENABLE` | **Yes.** New requests bypass; resident entries still drain normally. |
| `CFG_HOLD_SUBS_*` | **Mostly.** Raising it above what a resident entry can reach strands it until `serve_timeout` fires — the backstop exists, so it degrades rather than hangs. |
| `CFG_HOLD_WINDOW_*` | **Yes.** Only the reload value changes; counters already loaded run out as before. |
| `CFG_BANK_SHIFT_*` | **NO — correctness hazard.** |

The bank index both *places* an entry and *looks it up* (`req_bank = mshr_bank_of(...)`, `:1648`).
Change the hash with entries resident and a lookup probes the wrong bank: the line misses, a second
entry is allocated for an address that already has one, and two entries now shadow the same line.

**Therefore the hardware must reject bank-hash writes unless the MSHR is empty**, rather than trust
software to sequence it. Gate the write on `!(|mshr_q_valid)`; on violation drop the write and set a
sticky bit in `CFG_STATUS`. Software reads `CFG_STATUS` after configuring; a set bit is a programming
error, not a hint. Add a matching SVA (`bank_hash_stable_while_valid`).

## 6. Synthesis-time opt-out — keep the const-fold available

A config that pins `hold_window_burst = 0` today gets the **entire hold block deleted** — which is
why `sweep2047` prints no `hold_release` line at all. Making the window runtime means it can never
fold, so the four B-share=1 shapes would start carrying ~704 flops/group (`HoldCntW = 11` x 64) plus
the compare/decrement logic they currently do not have.

Resolution: a **synthesis-time** parameter `MshrCfgRuntime`.

- `0` — today's behaviour exactly; every CSR collapses to its elaborated constant and the hold block
  folds away. A fixed-function tapeout picks this.
- `1` — CSR-controlled. Characterisation and development builds pick this.

Same pattern as `EnableStats`. The flexibility must never become a tax that cannot be opted out of.

`HoldWindowHwMax = 2047` sets the counter width, and 11 bits x 64 entries is **already paid for at
today's shipping default** — so at `MshrCfgRuntime=1` the window CSR costs nothing beyond what ships
now.

---

# Software

## 1. Header — `software/runtime/mshr_cfg.h`

```c
// Group MSHR runtime configuration. Written through the group-barrier port's
// unused op encoding (bank field == 3); see docs/mshr_runtime_csr_design.md.
#define MSHR_CSR_ENABLE             0
#define MSHR_CSR_HOLD_SUBS_SINGLE   1
#define MSHR_CSR_HOLD_SUBS_BURST    2
#define MSHR_CSR_HOLD_WINDOW_SINGLE 3
#define MSHR_CSR_HOLD_WINDOW_BURST  4
#define MSHR_CSR_BANK_SHIFT_SINGLE  5
#define MSHR_CSR_BANK_SHIFT_BURST   6
#define MSHR_CSR_BANK_BURST_BITS    7
#define MSHR_CSR_SERVE_TIMEOUT      8   // response-side; NOT the hold window
#define MSHR_CSR_STATUS            15

// DERIVED, never hardcoded -- 16384 at 16 groups, 65536 at 64. A hardcoded <<14
// made the group barrier a silent no-op across the whole 8x8 campaign.
#define MSHR_WORD_STRIDE (4 * BANKS_PER_TILE * NUM_TILES_PER_GROUP * NUM_GROUPS)
#define MSHR_CSR_OP 3   // bank field encoding for an MSHR CSR write

static inline void mshr_cfg_write(uint32_t group, uint32_t csr, uint32_t val) {
  // A group-level write must target a tile in THAT group other than our own:
  // a same-tile access is TCDM_LOCAL and never reaches the group crossbar.
  uint32_t tile = (group == my_group()) ? ((my_tile() + 1) % NUM_TILES_PER_GROUP) : 0;
  volatile uint32_t *p = (volatile uint32_t *)
      (((GROUP_BARRIER_WORD + csr) * MSHR_WORD_STRIDE) +
       (group * GROUP_STRIDE) + (tile << 6) + (MSHR_CSR_OP << 2));
  *p = val;
}
```

## 2. Configuring — one core per group, before the benchmark region

Each group owns its own MSHR, so **all 16 must be written**; there is no broadcast. Cheapest is one
designated core per group writing its own group's CSRs in parallel, then a barrier.

```c
void mshr_cfg_apply(const mshr_cfg_t *c) {
  uint32_t g = my_group();
  if (my_tile() == 0) {                       // one writer per group
    mshr_cfg_write(g, MSHR_CSR_ENABLE, 0);    // quiesce first: bank-hash writes need an empty MSHR
    mshr_fence();                             // let resident entries drain
    mshr_cfg_write(g, MSHR_CSR_BANK_SHIFT_SINGLE, c->bank_shift_single);
    mshr_cfg_write(g, MSHR_CSR_BANK_SHIFT_BURST,  c->bank_shift_burst);
    mshr_cfg_write(g, MSHR_CSR_BANK_BURST_BITS,   c->bank_burst_bits);
    mshr_cfg_write(g, MSHR_CSR_HOLD_SUBS_SINGLE,  c->hold_subs_single);
    mshr_cfg_write(g, MSHR_CSR_HOLD_SUBS_BURST,   c->hold_subs_burst);
    mshr_cfg_write(g, MSHR_CSR_HOLD_WINDOW_SINGLE,c->hold_window_single);
    mshr_cfg_write(g, MSHR_CSR_HOLD_WINDOW_BURST, c->hold_window_burst);
    mshr_cfg_write(g, MSHR_CSR_SERVE_TIMEOUT,     c->serve_timeout);
    mshr_cfg_write(g, MSHR_CSR_ENABLE, 1);    // arm last
  }
  barrier_all();
}
```

**Ordering matters and is not optional:** disable -> drain -> program the hash -> program the rest ->
enable. The bank-hash CSRs are rejected by hardware unless the MSHR is empty (§5), so programming
them while enabled silently sets an error bit and leaves the old hash in place.

## 3. Call site

In `main()` immediately before the benchmark region, alongside the existing `csr_trace` enable — the
same place, the same phase boundary. Read `CFG_STATUS` afterwards and fail loudly if non-zero;
a rejected write means the configuration in effect is not the one requested, which is exactly the
class of silent-mismatch bug that cost three invalid runs on 2026-08-14.

## 4. Per-shape values

`scripts/gemm_autotune.py` already emits every one of these knobs. Extend it with a
`--emit-c-struct` mode producing an `mshr_cfg_t` initialiser, so the C side and the elaborated
default come from one source rather than being transcribed twice.

---

# Verification

| # | Gate | Method |
|---|---|---|
| V1 | **Reset values reproduce today** | Build `MshrCfgRuntime=1`, write no CSRs, run `256x512x256`. Must return **34,596** exactly. Any deviation means a reset value is wrong. |
| V2 | **`MshrCfgRuntime=0` is bit-identical to the current tree** | Same run, must return 34,596, and the netlist should be structurally unchanged. |
| V3 | **CSR-set == elaborated-constant** | For 3 shapes, run (a) today's per-shape flavour and (b) `MshrCfgRuntime=1` with the CSRs programmed to the same values. Cycle counts must match exactly. This is the real proof the CSR path works. |
| V4 | **R3 bypass semantics** | `hold_subs_burst = 1` on a B-share=1 shape must match the `hold_window_burst = 0` pin's result, and `[MSHRG]` must show zero burst allocations. |
| V5 | **Bank-hash rejection** | Program a bank-hash CSR with entries resident; the write must be dropped, `CFG_STATUS` set, and the run must complete correctly. |
| V6 | **Re-lint** | Spyglass after the change. The last run predates even the C1 width fix. |

V3 is the one that matters most: it is the difference between "the CSRs are wired" and "the CSRs
mean what the parameters meant".

---

# Risks and open questions

1. **`bar_op` widening touches the barrier decode**, which is on the critical path for a mechanism
   whose failure mode is a *silent* deadlock (a withheld response that never releases). Any change
   here needs the barrier's own regression, not just the MSHR's.
2. **16-bit CSR payload** is enough for every field listed, but `hold_window` at an 11-bit bound uses
   most of one. Raising `HoldWindowHwMax` past 65535 would need a wider payload path.
3. **Bank-hash quiesce may be awkward mid-kernel** if a future use wants to re-tune between phases.
   The empty-MSHR requirement is a correctness constraint, not a convenience one — a drain handshake
   would be the extension, not relaxing the gate.
4. **This adds a software step that can be skipped.** A benchmark that forgets `mshr_cfg_apply()`
   runs with `CFG_ENABLE = 0` — everything bypasses, which is *safe* but not what anyone intended,
   and it would look like "the MSHR does nothing". The `CFG_STATUS` check and a loud
   `[MSHR] cfg not applied` print at the benchmark boundary are worth the few lines.
