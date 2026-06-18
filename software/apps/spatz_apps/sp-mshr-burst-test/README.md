# sp-mshr-burst-test

Self-checking correctness regression for the **group MSHR**
(`hardware/src/mempool_group_mshr.sv`) and the **Spatz VLSU burst path**, for
TeraNoC + Spatz.

A single baremetal kernel (`main.c`, no data header) runs nine
barrier-separated phases that drive the MSHR through request merging, response
multicast, single-word vs. burst handling, sub-request **and** bank-full
overflow, peak occupancy, AMO / response cache, and the burst-allocator
`force_send` corner — plus the VLSU burst-shape generator (full / multi /
non-full / no-burst). Every golden value is **timing-independent**: data phases
read pre-initialised read-only shared arrays, AMO phases check deterministic
reductions. Each phase self-checks and ORs a bit into a shared fail mask; core 0
reports a single verdict.

Each phase writes its **phase number (1..9)** to the `trace` CSR (0x7d0) on entry
(`phase_begin(n)`) and `0` on exit (`phase_end()`). This (a) gates the `[CMS]`
scoreboard VIP and the group-MSHR `[MSHR stats]` per phase (each phase is its own
profiling window → one stats block per phase) and (b) is tapped by the TB as
`core_bench_phase` (added to `wave.tcl` as the **Benchmark_Phase** group), so the
waveform shows *which* phase the sim is in as a 1..9 staircase (0 = idle). The TB
gates on the full CSR value (`mempool_tb.sv`, `|`-reduction), so any non-zero phase
number enables profiling — using this needs one RTL recompile. (P8/P9 were folded
in from the former `mshr-capacity-test`, which this kernel now supersedes.)

## What it exercises

| Phase | What runs | MSHR / VLSU behavior targeted |
|------|-----------|-------------------------------|
| **P1** | Per-core `vle32`→`vse32` at VL=16/32/24/7 across LMUL=1/2/4, from a **remote** owner region | VLSU burst-shape generation (full burst, 2×16 multi-burst, burst+tail, non-full, no-burst multi-port) through the MSHR. Per-core base `rb` (mostly distinct; home groups 0/5/10/15 pile up — see *P1 source base addresses*). |
| **P2** | All active cores `lw` the **same** 8 words simultaneously | Single-word merge + response multicast; with `cores_per_group` (16) > `MshrMergeReqs` (8) the **sub-request overflow** path fires too. Requires `EnableMshrSingleReq`. |
| **P3** | Cores in a group `vle32` the **same** aligned 16-word region | Full-burst merge + multicast to all coalesced sub-requesters. |
| **P4** | One `amoadd.w(+1)` per active core | AMO reduction; deterministic final = #active cores. |
| **P5** | `L=4` `amoadd`s/core interleaved with loads of the same word | AMO-vs-load / AMO-vs-cache mix; deterministic final = `L × #active`. |
| **P6** | 4 back-to-back LMUL=2 (VL=32) bursts to a **remote** region | ROB pressure (4×32 beat-ids ≫ ROB=32) → burst-allocator / `force_send` corner. A true RTL deadlock here shows as the sim never reaching the verdict. |
| **P7** | 3 consecutive VL=16 **remote** bursts (48 beat-ids) | `meta_id` wrap across consecutive bursts. |
| **P8** | Each core bursts a remote line (`remote_line(cid)`) | *Intended:* peak occupancy / bank-full bypass. **Actual:** all 16 group-mates land on one line → they coalesce, so occupancy is **not** reached (see *Source addresses for P2–P9*). |
| **P9** | Repeated single-word remote load ×`CACHE_REPS` | Response-cache **hit** after the first fill — but the word is shared by the home group, not per-core (see address section). |

All the load phases target a **different group** than the issuing core via the
`remote_base` / `remote_line` / `l1_group_of` helpers (P1/P6/P7 read a remote
*owner* region; P8/P9 pick remote 64 B lines), drawn from the **full** `percore`
pool (which is fully initialised, so every line has a valid golden). This matters
because the group MSHR is **source-side** — it coalesces a group's *outgoing*
remote loads — so the traffic only allocates an MSHR entry if it leaves the
issuing core's group. Because the target group is chosen relative to the issuing
core, the test exercises the MSHR at **any** `ACTIVE_CORES`, including a single
core: one core in group 0 still loads from another group, allocating group 0's
MSHR. (P2/P3 now target a **group-1** line `cg`, so the merge phases coalesce even
when only group-0 cores are active; P4/P5 — AMO — read group-0 arrays, bypass the
MSHR, and are local for group-0 cores.)

## Verdict

The pass/fail result is the **EOC return value** = `g_fail`, a bitmask where bit
*p* is set if phase *p* failed (`0` ⇒ PASS). This avoids printf, whose stack
frame plus `main`'s overflows the 512 B per-core stack (`seq_mem_size`).

Build with `-DVERDICT_PRINTF` to also emit a human-readable UART line
(`sp-mshr-burst-test: PASS (cores=N)` or `FAIL mask=0x.. P2 P6 …`) and up to
`PRINT_CAP` (24) detailed `[FAIL] phase=.. core=.. idx=.. exp=.. got=..` lines.

Run it **alongside the core-memory scoreboard VIP** (`[CMS]` transcript lines):
the VIP catches MSHR-level over/under-delivery and stuck requests that the SW
data-checks cannot observe on their own.

## Build & run

```bash
# Build (any Spatz config; validated on terapool_spatz4_fpu)
cd software/apps/spatz_apps
make sp-mshr-burst-test config=terapool_spatz4_fpu
# optional human-readable verdict line:
make sp-mshr-burst-test config=terapool_spatz4_fpu RISCV_WARNINGS="-DVERDICT_PRINTF"

# Simulate (QuestaSim, headless)
cd ../../../hardware
app=apps/spatz_apps/sp-mshr-burst-test make -o update-floogen simc \
    config=terapool_spatz4_fpu buildpath=build_X
```

PASS ⇒ EOC `retval = 0`; a non-zero retval is the fail mask (e.g. `0x44` =
phases 2 and 6). A hang (no EOC) indicates a real RTL deadlock, most likely the
P6 `force_send` corner.

## Shared data & golden patterns

All shared state lives in `.l1_prio` (word-interleaved across every group, so
the loads are genuinely remote and traverse the MSHR):

| Symbol | Size | Golden / role |
|--------|------|---------------|
| `percore[NUM_CORES * 64]` | remote-target pool (P1/P6/P7/P8/P9) | `gold_pc(cid,i) = 0xB000_0000 + cid·0x1000 + i` |
| `percore[cg]` (P2/P3) | shared coalesce target, `cg = line_in_group(1)` = `0x20400` (group 1) | `gold_pc_w(cg+i)` |
| `amo_cnt`, `amo_mix` | AMO reductions (P4/P5) | checked against `#active` and `L·#active` |
| `g_fail`, `g_print` | shared fail mask / print counter | — |

Each active core initialises **only the remote regions it will read** — its
`remote_base` owner region plus its P8/P9 lines (`rb`/`w8`/`w9`, computed once and
reused by init and phases) — not the whole pool. So a single core inits ~96 words
instead of 16384, yet every loaded line still has a valid golden. The data is
read-only after the init barrier, which is what makes the checks independent of
NoC timing and arbitration order. The remote phases index `percore` by absolute
word index via `gold_pc_w(w) = gold_pc(w / PC_WORDS, w % PC_WORDS)`.

> Validated on `terapool_spatz4_fpu` at **`ACTIVE_CORES=1`**: PASS, EOC, and group
> 0's `[MSHR stats]` show it allocating single **and** burst entries (peak
> `mshr_valid_max=9`) — confirming a single core in group 0 exercises its
> source-side MSHR. (Before the remote-targeting fix the MSHR was never allocated.)

## Tunables (compile-time `#define`)

| Macro | Default | Meaning |
|-------|---------|---------|
| `ACTIVE_CORES` | `0` (= all cores) | restrict the participating cores (e.g. `1` single-core, `16` one group). P2/P3 coalesce with ≥2 cores in a group (target is remote group 1, so even group-0-only works); P8 peak-occupancy still wants many cores. `0` = full stress. |
| `PC_WORDS` | `64` | per-core golden region (covers P7's 3×16 wrap) |
| `BUF_WORDS` | `32` | local result buffer; kept small so `main`'s frame fits the 512 B stack, which caps the largest single `vle` at VL=32 |
| `COALESCE_GROUP` | `1` | group the P2/P3 shared target (`cg`) lives in — remote to every other group, so the merge phases coalesce even at `ACTIVE_CORES=16` (one group) |
| `CACHE_REPS` | `8` | repeated single-word remote loads in P9 (response-cache hits) |
| `PRINT_CAP` | `24` | max detailed `[FAIL]` lines (with `-DVERDICT_PRINTF`) |

## Portability

Self-checking on any Spatz (RVV + group-MSHR) config. The *intensity* of the
merge/overflow phases scales with `cores_per_group`: at 16 cores/group
(`mempool_spatz4_fpu`, `terapool_spatz4_fpu`) P2 exceeds `MshrMergeReqs=8` and
drives the overflow path; with fewer cores/group those phases still pass but
exercise merging less aggressively. The phase logic itself is config-agnostic
(it reads `NUM_CORES` and the runtime core/group helpers).

## P1 source base addresses (`ACTIVE_CORES=0`, terapool 256c / 16g)

In P1 each core's five `vld`s share **one** base, `rb = remote_base(my_group, cid)`
(`percore` @ `0x20000`); they differ only in VL/LMUL (the burst *shape*), not the
address. Across cores the base follows a regular per-home-group pattern: the 16
cores of a home group step by **`0x100`** (256 B = 4 tiles) across **4 consecutive
remote groups** (4 cores per target group, at tile-in-group 0/4/8/12). Because
`remote_base` scans *forward* from owner `cid` to the first remote owner, home
groups **0, 5, 10, 15** have a 4–5 core **pile-up** on a single base (those cores
then coalesce in their source group's MSHR — so P1 is not strictly "no-merge" for
them; everywhere else each core hits a distinct line). Full map:

home | cid range | per-core P1 base addr (one per core, 0x.....)                         | target grps        | collision
-----|-----------|------------------------------------------------------------------------|--------------------|-----------
   0 |   0-15   | 20400 20400 20400 20400 20400 20500 20600 20700 20800 20900 20a00 20b00 20c00 20d00 20e00 20f00 |  1  1  1  1  1  1  1  1  2  2  2  2  3  3  3  3 | 0x20400x5
   1 |  16-31   | 21000 21100 21200 21300 21400 21500 21600 21700 21800 21900 21a00 21b00 21c00 21d00 21e00 21f00 |  4  4  4  4  5  5  5  5  6  6  6  6  7  7  7  7 | -
   2 |  32-47   | 22000 22100 22200 22300 22400 22500 22600 22700 22800 22900 22a00 22b00 22c00 22d00 22e00 22f00 |  8  8  8  8  9  9  9  9 10 10 10 10 11 11 11 11 | -
   3 |  48-63   | 23000 23100 23200 23300 23400 23500 23600 23700 23800 23900 23a00 23b00 23c00 23d00 23e00 23f00 | 12 12 12 12 13 13 13 13 14 14 14 14 15 15 15 15 | -
   4 |  64-79   | 24000 24100 24200 24300 24400 24500 24600 24700 24800 24900 24a00 24b00 24c00 24d00 24e00 24f00 |  0  0  0  0  1  1  1  1  2  2  2  2  3  3  3  3 | -
   5 |  80-95   | 25000 25100 25200 25300 25800 25800 25800 25800 25800 25900 25a00 25b00 25c00 25d00 25e00 25f00 |  4  4  4  4  6  6  6  6  6  6  6  6  7  7  7  7 | 0x25800x5
   6 |  96-111  | 26000 26100 26200 26300 26400 26500 26600 26700 26800 26900 26a00 26b00 26c00 26d00 26e00 26f00 |  8  8  8  8  9  9  9  9 10 10 10 10 11 11 11 11 | -
   7 | 112-127  | 27000 27100 27200 27300 27400 27500 27600 27700 27800 27900 27a00 27b00 27c00 27d00 27e00 27f00 | 12 12 12 12 13 13 13 13 14 14 14 14 15 15 15 15 | -
   8 | 128-143  | 28000 28100 28200 28300 28400 28500 28600 28700 28800 28900 28a00 28b00 28c00 28d00 28e00 28f00 |  0  0  0  0  1  1  1  1  2  2  2  2  3  3  3  3 | -
   9 | 144-159  | 29000 29100 29200 29300 29400 29500 29600 29700 29800 29900 29a00 29b00 29c00 29d00 29e00 29f00 |  4  4  4  4  5  5  5  5  6  6  6  6  7  7  7  7 | -
  10 | 160-175  | 2a000 2a100 2a200 2a300 2a400 2a500 2a600 2a700 2ac00 2ac00 2ac00 2ac00 2ac00 2ad00 2ae00 2af00 |  8  8  8  8  9  9  9  9 11 11 11 11 11 11 11 11 | 0x2ac00x5
  11 | 176-191  | 2b000 2b100 2b200 2b300 2b400 2b500 2b600 2b700 2b800 2b900 2ba00 2bb00 2bc00 2bd00 2be00 2bf00 | 12 12 12 12 13 13 13 13 14 14 14 14 15 15 15 15 | -
  12 | 192-207  | 2c000 2c100 2c200 2c300 2c400 2c500 2c600 2c700 2c800 2c900 2ca00 2cb00 2cc00 2cd00 2ce00 2cf00 |  0  0  0  0  1  1  1  1  2  2  2  2  3  3  3  3 | -
  13 | 208-223  | 2d000 2d100 2d200 2d300 2d400 2d500 2d600 2d700 2d800 2d900 2da00 2db00 2dc00 2dd00 2de00 2df00 |  4  4  4  4  5  5  5  5  6  6  6  6  7  7  7  7 | -
  14 | 224-239  | 2e000 2e100 2e200 2e300 2e400 2e500 2e600 2e700 2e800 2e900 2ea00 2eb00 2ec00 2ed00 2ee00 2ef00 |  8  8  8  8  9  9  9  9 10 10 10 10 11 11 11 11 | -
  15 | 240-255  | 2f000 2f100 2f200 2f300 2f400 2f500 2f600 2f700 2f800 2f900 2fa00 2fb00 20000 20000 20000 20000 | 12 12 12 12 13 13 13 13 14 14 14 14  0  0  0  0 | 0x20000x4

## Source addresses for P2–P9 (`ACTIVE_CORES=0`, terapool 256c / 16g)

Unlike P1, the other phases use a **fixed shared** address, or reuse P1's `rb`, so
most don't need a 256-row table. Summary (then details):

| Phase | source | base across cores | MSHR effect |
|------|--------|-------------------|-------------|
| P2 | `percore[cg]` (8 words; `cg=line_in_group(1)`=`0x20400`) | **same** for all cores | in **group 1** → remote to every group ≠ 1, so those cores single-word **coalesce** (16/grp > `MshrMergeReqs`=8 ⇒ overflow); incl. all 16 group-0 cores at `ACTIVE_CORES=16` |
| P3 | `percore[cg]` (16-word burst) | **same** for all cores | same `cg` (group 1) → burst **coalesce** + multicast for every group ≠ 1 |
| P4 | `amo_cnt` @ `0x30180` | **same** for all cores | AMO → **bypasses** the MSHR |
| P5 | `amo_mix` @ `0x301c0` | **same** for all cores | AMO + `lw` same word; AMO bypasses |
| P6 | `percore[rb]` | **per-core, == P1's `rb`** (see P1 table) | alloc (4× LMUL=2 burst); same 0/5/10/15 pile-ups as P1 |
| P7 | `percore[rb, rb+0x40, rb+0x80]` | **per-core, == P1's `rb`** (3 lines) | alloc; same pile-ups as P1 |
| P8 | `percore[remote_line(cid)]` | **1 line per home group** (⚠ not distinct) | 16 group-mates **coalesce** → not peak occupancy |
| P9 | `percore[remote_line(cid+1)]` | **same line as P8** per group | shared single word → coalesce + cache hit |

### P2–P5
One fixed address each, identical for every core. **P2/P3** target
`cg = line_in_group(COALESCE_GROUP)` = `0x20400` (**group 1**), remote to every group
≠ 1, so each such group's active cores **coalesce** there — incl. all 16 group-0
cores at `ACTIVE_CORES=16` (they merge in group 0's MSHR). **P4/P5** target
`amo_cnt`/`amo_mix` (**group 0**); AMOs bypass the MSHR and are local for group-0 cores.

### P6 / P7
Reuse P1's per-core base `rb = remote_base(my_group, cid)` — **identical to the P1
table above**. P6 issues 4× LMUL=2 VL=32 bursts from `rb`; P7 reads 3 consecutive
lines `rb`, `rb+0x40`, `rb+0x80`.

### P8 / P9  ⚠ collapse to one line per home group
`remote_line(my_group, cid)` scans forward from line `cid` to the first line
*outside* the home group, so **all 16 cores of a home group land on the same line**
(P9 with `cid+1` lands on the same one). So P8 does **not** create a distinct line
per core (its group-mates coalesce into ~1 entry instead of filling 16 → no peak
occupancy), and P9's single-word reads are shared, not per-core (still a cache hit).

|home g | base (all 16 cores) | tgt grp  |
|-------|---------------------|----------|
|    0  |      0x20400        |    1     |
|    1  |      0x20800        |    2     |
|    2  |      0x20c00        |    3     |
|    3  |      0x21000        |    4     |
|    4  |      0x21400        |    5     |
|    5  |      0x21800        |    6     |
|    6  |      0x21c00        |    7     |
|    7  |      0x22000        |    8     |
|    8  |      0x22400        |    9     |
|    9  |      0x22800        |   10     |
|   10  |      0x22c00        |   11     |
|   11  |      0x23000        |   12     |
|   12  |      0x23400        |   13     |
|   13  |      0x23800        |   14     |
|   14  |      0x23c00        |   15     |
|   15  |      0x24000        |    0     |

To make P8 fill *distinct* entries (true peak occupancy), the slot must
spread cores across distinct remote lines (e.g. `remote_line(my_group, cid +
NumTilesPerGroup)` or a per-core stride) — say so and I'll change it.
