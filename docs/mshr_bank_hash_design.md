# MSHR Bank-Select Hash — measurement + improved mixer

**Status: MEASURING + PROTOTYPED (2026-07-18).** Knob `group_mshr_bank_hash` (0 = legacy,
1 = xorshift-mixed), plus a `[BFBHASH]` concentration probe. Companion to
`docs/mshr_request_hold_design.md` §5c (the bank-full overflow this addresses).

## 0. Address layout & MSHR indexing (terapool_spatz4_fpu)

**Byte-address decode** (MemPool word-interleave). Field widths: `ByteOffset = log2(BeWidth) = 2`
(32-bit words); `log2(NumBanksPerTile) = 2`; `log2(NumTilesPerGroup) = 4`; `log2(NumGroups) = 4`.
Decode at `mempool_tile.sv:1192` (group) and the tgt_addr repack at `:1170`/`:1181`:

```
bit:    31 .............. 12 | 11 10  9  8 | 7  6  5  4 | 3  2 | 1  0
field:  bank_row (in-bank)   |   GROUP     |    TILE    | bank | byte
        └ TCDMAddrMemWidth ┘   └ 4 bits ┘    └ 4 bits ┘  └2b┘   └2b┘
```
Consecutive words round-robin bank → tile → group; a full sweep of all `NumBanks` banks is one
1024-word / 4 KB span, then `bank_row` advances.

**Target NoC group** (which remote group a request routes to) =
`addr[ByteOffset + log2(BanksPerTile) + log2(TilesPerGroup) +: log2(NumGroups)]` = **byte-addr
[11:8]** here. Carried on the request as `tgt_group_id`.

**Which group's MSHR a request enters = the SOURCE core's group**, NOT the address. The group MSHR
is source-side (`mempool_group.sv:451-458`: fed by the group's own tiles' `tcdm_master_req`, output
to `tcdm_master_req_o → NoC`); it coalesces *outgoing* remote requests issued by its own 16 cores.
Consequence: two cores coalesce only if they share a source group (hence the matmul B-sharing is
degree-2 — the two m-block cores of a p-strip). `hartid = (group<<4)|tile`.

**Which BANK within that MSHR = a hash of the target address** (this is what
`group_mshr_bank_hash` selects): `req_bank = mshr_bank_of(req_addr_key, tgt_group_id)`
(`mempool_group_mshr.sv:1075`). `req_addr_key` is the tgt_addr (group field removed), layout
`{bank_row, bank_in_tile(2b), tile(4b)}`; the fold runs from `BurstAlignBits = log2(MaxBurstWords)
= 4` upward (so a 16-word burst's beats share a bank) and XORs in `tgt_group` as the seed. **This
fold is hash 0.** The *way* within the bank (1 of `MshrWaysPerBank`=4) is allocation arbitration
(RR / first-free), not address-based.

Three-level summary: **group MSHR** ← source core (hartid, not hashed); **bank** ← address hash
(`mshr_bank_of`, §2/§4); **way** ← arbitration.

## 1. Question

The group MSHR has 64 entries = 16 banks × 4 ways. A request is pinned to a bank by
`mshr_bank_of(line_addr, group)` — it *must* be a pure function of the line address so that two
cores loading the same line hash to the same bank and coalesce. Measured behavior on matmul:
real MSHR occupancy averages only ~15/64 (peak ~38) yet ~40% of mergeable requests bank-full
bypass. Two candidate causes, indistinguishable in run-total statistics:

- **Concentration** — the hash sends a temporal batch of *distinct* lines into a few banks; those
  banks' 4 ways fill while others sit empty. A better hash spreads the batch → more entries used.
- **Aggregate fullness** — the whole MSHR is full during synchronized launch waves. Only more
  ways/entries help; a hash does nothing.

## 2. The legacy hash and its concentration failure mode

`mshr_bank_of` (BankHash = 0) XOR-folds address bits above the burst-align boundary onto bank
bits with a fixed stride:

```
b = group;
for (i = BurstAlignBits .. top)  b[(i - BurstAlignBits) mod BankIdW] ^= addr[i];
```

Every address bit `i` maps to exactly **one** bank bit, `(i - align) mod BankIdW`. With BankIdW = 4,
address bits whose position shares a residue class mod 4 (e.g. bits 4, 8, 12, 16, …) all drive the
**same** bank bit. So a concurrent working set whose members differ only in one such residue class
(a stride that is a high power of two — common in matmul row/column walks) toggles a single bank
bit → the whole batch collapses onto **2 of 16 banks**. That is invisible in run-total per-bank
overflow (the hot pair rotates over the run, averaging flat), which is why the earlier "uniform
overflow" reading did **not** rule this out.

## 3. Measurement: `[BFBHASH]` probe

At every bank-full-bypass event (`req_bankfull_bypass_dbg`), sample `popcount(bank_has_free)` —
how many *other* banks could have taken the request. Accumulated (translate_off, one final line
per group MSHR):

- `avg_free_banks` — mean free banks at the moment of an overflow. **High ⇒ concentration**
  (the request bounced off a full bank while many banks had room); **~0 ⇒ aggregate full.**
- `alias_events` — overflow events with ≥ half the banks free (clear "could have gone elsewhere").
- `full_events` — overflow events with zero banks free (genuine aggregate full).

Decision rule: `avg_free_banks` well above 0 (say ≥ 4 of 16) confirms concentration and motivates
the hash; `alias_events ≫ full_events` is the same conclusion.

## 4. Improved mixer (BankHash = 1)

Pre-mix the line index with an xorshift before the fold, so entropy from every position reaches
every bank bit and no single residue class of address bits owns a bank bit:

```
mix = line;                 // line = addr >> BurstAlignBits
mix ^= mix >> 7;
mix ^= mix >> 13;
mix ^= mix >> 17;
b = group;
for (i = 0 .. top)  b[i mod BankIdW] ^= mix[i];
```

- **Coalescing-safe**: still a pure function of {group, line} → same line → same bank, always.
  No response-path or merge-logic change.
- **Cheap**: shifts are wiring, the whole thing is a few XOR levels — no multiplier, no timing
  cliff. Still GF(2)-linear, but with a mixing matrix whose kernel no longer aligns with
  power-of-two strides. The odd shift amounts (7, 13, 17), all non-multiples of BankIdW ≤ 4, cross
  residue classes so a one-class difference is spread across all bank bits.
- **Honest limitation**: any linear hash has *some* colliding stride; this defeats the specific
  power-of-two-stride collapse the legacy fold suffers, validated empirically by the A/B rather
  than claimed universal. A multiplicative (Knuth) hash would be stronger but needs a multiply in
  the request path (timing risk) — deferred unless the xorshift proves insufficient.

## 5. Verification / A/B plan
1. `[BFBHASH]` on the **legacy** build (BankHash 0) — settles concentration vs aggregate-full.
2. If concentration: A/B matmul BankHash 0 vs 1 — `avg_free_banks` should drop, overflow /
   no-entry bypass fall, merge rate and MSHR occupancy rise.
3. Coalescing correctness: `sp-mshr-burst-test` PASS + 0 CMS warnings under BankHash 1 (the
   same-line→same-bank invariant is structural, but verify end-to-end).
4. Caveat: matmul *cycles* may not move (latency-bound, per §5c / the m128 result) — judge on
   utilization / overflow / NoC traffic; the cycle effect is a bonus, not the metric.

## 6. Results (2026-07-18, clean 16-banner runs)

**Concentration confirmed (BankHash 0 probe, matmul):** 28,400 bank-full bypasses, **avg 13.49 of
16 banks free** at each, 100% alias / **0 aggregate-full**. The overflow is pure concentration —
the address hash pinning temporal batches to a couple of banks — not capacity. (Also explains why
`group_mshr_num=128` barely helped: the entries always existed; the hash just couldn't reach them.)

**A/B (matmul, BankHash 0 vs 1), both clean, accepted=138,481 identical:**

| metric | hash 0 | hash 1 |
|---|---|---|
| bank-full bypasses (`[BFBHASH]`) | 28,400 | 27,433 (−3.4%) |
| avg free banks at overflow | 13.49/16 | **13.45/16** (unchanged) |
| kernel cycles | 3836 | 3833 (noise) |
| merge rate | 14.3% | 13.5% |
| merged (s / b) | 19,841 (19,011 / 830) | 18,712 (18,155 / 557) |
| allocs | 32,955 | 34,992 |

**Coalescing correctness:** `sp-mshr-burst-test` PASS under BankHash 1 — 0 CMS warnings, merges
healthy. The same-line→same-bank invariant holds (structural).

**Verdict — the simple (linear) xorshift hash FAILS to fix the concentration.** Bank-full bypass
barely moves (28,400 → 27,433) and `avg_free_banks` stays at 13.45/16 — i.e. every overflow still
happens with ~13 of 16 banks empty; the batch still collapses onto ~2–3 banks, just a *different*
2–3. Root reason: XOR and shift are **GF(2)-linear**, so both the legacy fold and the xorshift are
linear maps address→bank. A linear map cannot de-concentrate a working set whose concurrent
address differences lie in (a coset of) the map's kernel — it only permutes *which* addresses
collide, not *whether* the batch concentrates. The matmul batch has exactly such an affine
structure, so any linear hash keeps it concentrated. The merge/cycle shifts are pure re-timing
from the reshuffled collisions, not a real effect.

**Correction note:** an earlier revision of this section reported "28,400 → 0 / eliminated." That
was a measurement-reading error — the `[BFBHASH]` counters print in the SystemVerilog `final`
block at *sim exit*, later than the `[UART] took N cycles` line; the aggregation was run in the
window after UART but before the final block, so it matched zero BFBHASH lines and misread that as
zero events. Lesson: gate final-block-counter reads on the sim-EXIT marker (`Simulation returned` /
`End time`), never on the UART cycle line.

## 7. MEASURED root cause (2026-07-18, address capture) — it is not stride aliasing

The `[BFBADDR]` probe (`+GROUP_MSHR_BANK_DUMP`) dumps `{addr_key, tgt_group, bank}` of every
bank-full bypass in group 0. On matmul the colliding requests look like:
```
key=a03 tgtgrp=1 bank0=11    key=a08 tgtgrp=1 bank0=11    key=a0e tgtgrp=1 bank0=11 ...
```
They differ **only in `addr_key[3:0]`** and all map to the **same bank**. Those 4 bits are the
**tile field** of `tgt_addr` (§0), and **both hash 0 and hash 1 fold from `BurstAlignBits = 4`
upward — they discard the tile field entirely** (hash 1 does `addr >> BurstAlignBits`). The
colliding requests are scalar A-loads to the *same* bank-row of *different* tiles — genuinely
distinct addresses that each deserve their own entry, but the hash drops the only bits that tell
them apart, so all ~16 collapse onto one bank's 4 ways → overflow while ~13 banks sit empty. This
is why hash 1 was bit-identical to hash 0 (it drops the same bits), and why my earlier
"stride-aliasing / need a non-linear hash" diagnosis was **wrong**.

Offline scoring of candidate hashes on the captured real addresses (avg distinct banks reached per
40 ns concurrency window; higher = better spread):

| hash | avg distinct banks/window | max bank load |
|---|---|---|
| legacy (h0) | 1.84 | 73 |
| xorshift (h1) | 1.84 | 73 |
| tile-only (`addr[3:0]^grp`) | 4.43 | 61 |
| **fold-from-0 / legacy-fold ⊕ tile ⊕ grp** | **4.50** | 62 |
| multiplicative (full key) | 4.40 | 63 |

**Fix (`group_mshr_bank_hash = 2`):** the legacy fold of `addr_key[BurstAlignBits:]` **plus a XOR
of `addr_key[BurstAlignBits-1:0]` (the tile field)** into the bank index. Cheap (4 extra XOR2),
coalescing-safe (still a pure function of {group, full addr_key}; aligned bursts have those low
bits = 0 so their bank is unchanged), and ~2.4× better spread on the real traffic. A non-linear
multiplicative hash is *not* needed — the problem was dropped bits, not a bad mixer.

## 8. hash 2 (fold+tile) RESULT (2026-07-18): near-total overflow elimination + 2.6x coalescing

Clean A/B (bank_hash=2 vs 0, num=64, hold=0, drain=2, accepted=138,480 == baseline):

| metric | legacy (0) | fold+tile (2) |
|---|---|---|
| bank-full bypasses | 28,400 | **120** (−99.6%) |
| merge rate | 14.3% | **37.7%** |
| merged single / burst | 19,011 / 830 | 45,357 / 6,879 |
| cache hits | 5,069 | 29,939 |
| kernel cycles | 3836 | **3786** |

The dropped-tile-bits fix works spectacularly. Mechanism: spreading distinct addresses across banks
stops bank-full eviction → entries **persist** → coalescing partners arrive in time → merges
explode (A-load +139%, B-load +729%). It is the only change in the whole campaign that moved the
kernel (3786 vs 3836 — small, since latency-bound, but real). Correction: the earlier "27,433 /
13.5% / no improvement" figure was **hash 1** (xorshift, which drops the tile bits exactly like the
legacy fold); **hash 2 is the actual fix**.

**Strategic conclusion — fold, don't field-select.** hash 2 is **stride-agnostic**: it folds every
address bit, so it needs no N, no shift, no CSR. That fully resolves the SW-config-vs-hardwired
tension — the answer is to fold all bits (so the stride is irrelevant), not to make a field-select
programmable. Measured spread confirms fold (4.50 distinct banks/window) > field-select (2.66).
Remaining question: whether the field-select `[5:3]` at **32 entries** (half the MSHR area) can
match the fold at 64 entries — under evaluation.
