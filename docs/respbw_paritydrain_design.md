# ParityDrain + TwinROB0 — uniform 2-beat/cycle burst response drain (design v2)

**Status: IMPLEMENTED AND VERIFIED (2026-07-12). Supersedes the modal "beat-spread / Option A"
(commits `523c23c`/`7d164fc`), deleted wholesale by this implementation.**

> **Verification results (§10 matrix, all green, zero CMS warnings on every ON run):**
> OFF (default): bit-identical legacy behavior — burst-test PASS at the identical EOC timestamp,
> distinct `cyc=3954`, matmul `4453` cycles (all exact legacy numbers).
> ON (`group_mshr_drain_beats=2`): burst-test PASS; distinct streaming `cyc=3121` (**1.27×**);
> **local-target sweep (the Option-A wedge geometry) completes, `cyc=3046`**; 16-core same-line
> `cyc=2900` (**2.8× vs Option A's 8044** — merging + 2-wide multicast compose);
> **matmul `4009` vs `4453` cycles = 1.11× speedup** (utilization 45.9%→51.0%) on the workload
> Option A deadlocked. Adversarial 3-reviewer implementation review: zero blocker/major findings;
> the two minor findings (missing §6 runtime assert, ROB OFF tie-off) are fixed.

Provenance: 8-agent design workflow (2 RTL-grounding readers → 3 independent designs → 3 adversarial
judges with disjoint lenses). All three designs converged on the same core architecture; all three
judges independently picked this variant ("ParityDrain + TwinROB0") as the only one whose port-1
classification is per-id and self-emptying rather than instruction-mode-coupled. Two grafts from the
losing variants are folded in (§6.3, §5.4). Grounding anchors cited inline were re-derived from the
RTL by the readers and re-verified by the judges.

---

## 1. Directive and rationale

User directive: *the 2-beats/cycle design must stay structurally the same as the 1-beat/cycle design —
same transaction contract, same MSHR coalescing — only the actual bandwidth doubles, making the most
of each tile's remote resp ports.*

Why the shipped Option A fails that directive: it introduced a per-request **mode** (flag bit +
`aux_base` in the request's spare `wdata.data`) and made flagged bursts **non-mergeable in both
directions**. That is not a detail — it is the root of the observed failure: in `sp-fmatmul`
(M=N=P=128, 256 cores), the 16 cores of each group load the *same* B-lines; non-mergeable means 16
separate entries per line contending for one 4-way MSHR bank, and the resulting pileup **wedges the
kernel** (requests frozen from cyc ~12k; OFF completes the kernel in 4453 cycles). Coalescing and the
2-wide receive must compose, not exclude each other.

## 2. Contract (the whole design in one paragraph)

The wire/transaction contract is **bit-identical legacy**:

- **Request:** `{addr, id = ROB0 base B (write-pointer captured at alloc cnt==0), burst_len ∈ {1,16},
  core_id = flat core port (1 for VLSU bursts), wdata.data = '0}`. No flag. No aux_base.
- **Response:** beat `b` of any entry carries `meta_id = sub_reqs[s].meta_id_base + b` — one
  contiguous (mod-32) id range per requester per burst, exactly the legacy math.
- **Merge/multicast/response-cache/bypass semantics: untouched.** Bursts merge in both directions;
  one entry + `sub_reqs[8]` serves up to 8 same-line requesters with one NoC fetch.

The **only** delta vs legacy is drain-stage *physicality*, applied uniformly to every `burst_len>1`
entry (no per-request mode): beat `b` leaves the MSHR on tile resp port `1+(b&1)` with
`rdata.core_id = sub_reqs[s].core_id + (b&1)`. The retag is computed at the `resp_out` drive **only**
— stored entry state, ingress dup/CACHED matching (`mshr:858/:1543`), and the slave-side `core_id`
echo all still see the original `core_id`. `burst_len==1` entries take the byte-identical legacy path
(`b=0` ⇒ `+0` retag is the identity; `map_resp_port_id`, resp-cache, CACHED replay untouched).

Because VLSU bursts always originate on core port 1, even beats land on core data port 1 (VLSU mem
port 0) and odd beats on core data port 2 (VLSU mem port 1): two distinct `core_id`s ⇒ the tile
`stream_xbar` (which routes by `core_id` alone, `mempool_tile.sv:869`) delivers **2 beats/cycle into
one core with zero tile-datapath change** (`:943`: per-input demux by core_id, per-output rr-arb; two
different outputs never collide; VLSU resp ports are always-ready, `spatz_mempool_cc.sv:293`).

The receiver re-maps with state it already owns: all 16 ids stay **one contiguous ROB0 range**; odd
beats arriving on mem port 1 are written into ROB0 through a **second slot-addressed write port**
(`rob_wid2 = rsp[1].id` — always a slot ROB0 itself allocated); consumption is a **dual-head in-order
pop** (`mem[rp]`, `mem[rp+1]`) feeding the existing 2-wide commit lane math.

## 3. What is deleted (Option A inventory)

| item | where |
|---|---|
| request flag `wdata.data[0]` + `aux_base` `data[IdWidth:1]` | `spatz_vlsu.sv` req mux |
| `beat_spread` + `aux_base` entry fields (−6 bits/entry) | `mempool_group_mshr.sv` entry struct |
| `req_beat_spread` decode | `mshr:599, :649-651` |
| non-merge gates (both directions) | `mshr:906-910, :934-939` |
| M4 meta-overlap skip | `mshr:934-939` |
| M5 must-allocate stall arm | `mshr:1401-1434` |
| beat-spread pre-pass, drive + ATOMIC FIRE, finalize | `mshr:1677-1708, :1796-1844, :1919-1949` |
| VLSU `mem/commit_beat_spread` + tail exclusion + `bs_target` steering + spread-ROB `rob_req_id` forwarding | `spatz_vlsu.sv:145-183, :1163-1175, :1371-1373` |
| wedge probes (both files) | temp blocks |

## 4. MSHR side: the parity drain

### 4.1 Drive-stage retag (uniform law)
For every `DRAIN_RESP` entry with `burst_len>1`: the drain may present up to 2 buffered beats per
cycle per subscriber, beat `b` on port `1+(b&1)`, `core_id_s + (b&1)`, `meta_id_base_s + b`. Port
choice, core_id math and meta_id math are pure functions of `(boff, sub_req)` — 1-wire parity, 3-bit
+1 adder, no state.

### 4.2 Port arbitration
Unchanged skeleton: bypass keeps strict priority (`port_taken` from `resp_in_valid && !resp_is_mshr`
before any drain select); a claimed drain beat holds its port until handshake. Parity pins a beat's
port, so a same-parity pair in the 2-slot `resp_buf` window drains 1/cycle (bounded perf dip, §8.2).

### 4.3 Multicast at 2-wide
`sub_reqs[8]` with one `meta_id_base` each is unchanged. `beat_pending` widens from one per-sub bit
to a per-buffered-slot × per-sub mask (net +2 bits/entry after the Option-A field deletions) so beats
`2k` and `2k+1` can multicast concurrently to a subscriber's two ports.

### 4.4 Re-delivery protection (graft, replaces ATOMIC FIRE)
Per-slot delivery state is **eager-initialized at response capture** (when ingress writes a
`resp_buf` slot, its per-sub pending mask is set once from the then-valid sub_reqs — legality already
proven by the existing merge-freeze `mshr_resp_seen_now`/`mshr_resp_inflight` blocks) and cleared per
handshake. A delivered beat can never be re-selected because its pending bit is gone — re-delivery is
*structurally* impossible instead of gated by a cross-port fire condition. The atomic-fire coupling
(and its port-idle cost under divergent ready) is deleted.

### 4.5 N=1 build (graft)
The legacy `DrainMultiPort` else-branch is kept **verbatim** for `DrainBeatsPerEntry==1`; the
generalized per-slot drain elaborates only at N=2. This is what makes the "OFF = bit-identical legacy
netlist" A/B property real rather than aspirational.

## 5. VLSU side: TwinROB0

### 5.1 reorder_buffer.sv (our fork) — two parameter-gated extensions, defaults legacy-identical
- `NumWrPorts=2`: adds `data2_i/id2_i/push2_i` as one extra `mem_d[id2_i]/valid_d[id2_i]` assignment
  (no pointer interaction; assertion `push_i && push2_i |-> id_i != id2_i`).
- `NumRdPorts=2`: adds a second read head `mem_q[rp+1]`/`valid_q[rp+1]` and a pop-2 mode
  (pointer += 2). Store-FIFO usage and ROBs 1–3 elaborate bit-identically (params default 1).

### 5.2 Burst id allocation — pure legacy
All 16 ids for a burst come from ROB0, 1 id/cycle (the existing alloc walk); base captured at
`cnt==0`. No steering, no second base. Request `id = B`, `burst_len=16`, exactly legacy.

### 5.3 Port-1 arrival classifier
A **32×1b `burst_odd_expected` bitmap indexed by `rsp.id`**:
- SET by the existing alloc walk on `burst_alloc_fire` when `cnt[0]==1` (direct FF decode of
  `rob_id`, no shifter);
- CLEARED on any consuming push of that id (either port — this keeps it coherent when a bank-full
  mergeable miss legally **bypasses** the MSHR and all beats funnel 1-wide to port 0).

A port-1 response with `burst_odd_expected[rsp.id]` set is an odd burst beat → ROB0 write port 2;
otherwise it is a native port-1 single (strided/indexed mode) → ROB1 as today.

**Soundness invariant** (judge-verified): op-queue serialization — the mem FSM holds one instruction
until `commit_insn_pop` retires it (`spatz_vlsu.sv:448-452`) — guarantees ROB1 never has outstanding
loads while any expected-odd bit is set. `switch_to_tail` additionally requires the pending drain
(`mem_pending[0]==0` ⇒ bitmap empty) before ports 1–3 re-enable. Runtime assertions:
`|burst_odd_expected| |-> mem_pending[1]==0`, and bitmap-empty at instruction retire.

### 5.4 Commit
The existing 2-wide commit lane math is kept (`lane = (burst_elem_idx+p)&(N_FU-1)`, counters advance
`2*ELENB`), now fed by ROB0's dual heads instead of two ROBs. Pairs never straddle the burst region:
`burst_full_bytes_commit` is a multiple of 64B, so 2-wide pairs stay row-aligned; the tail region
commits 1-wide legacy. **The Option-A tail exclusion is removed** (necessary — the MSHR retags all
bursts uniformly) and is safe precisely because everything lands in ROB0.

## 6. Tile + config

Zero tile datapath change. New elaboration guards: `MshrDrainBeats==2` requires `NumCoresPerTile==1`
(flat core_id arithmetic), `NumRemoteRespPortsPerTile>=3`, and core-port `1+1 <=` data-port count.
Retag range is safe by construction (base is always core port 1 → retag ∈ {1,2}; singles are
identity) + runtime assert. Same opt-in knob (`group_mshr_drain_beats`, default off).

## 7. Walkthroughs

**(i) Lone 16-beat burst.** VLSU allocates ids B..B+15 from ROB0 (bitmap odd bits set), issues
`{id=B, len=16}`. MSHR entry (1 sub_req) buffers beats; drain emits beat 0 on port 1/`core_id 1` and
beat 1 on port 2/`core_id 2` in one cycle, etc. Tile xbar delivers both to VLSU ports 0/1; port-0
push writes ROB0[B+2k] natively, port-1 push classifies via bitmap → ROB0.wr2[B+2k+1]. Dual-head pop
commits 2 elements/cycle. 8 cycles/burst drain (vs 16 legacy).

**(ii) 16 same-line cores (matmul shared-B).** All 16 requests **merge** into one entry (2 entries × 8
sub_reqs given `MshrMergeReqs=8`) → 1–2 NoC fetches instead of 16. The multicast drain serves each
subscriber's tile at up to 2 beats/cycle with that subscriber's own `meta_id_base + b` and
`core_id_s + (b&1)`. No bank exhaustion, no M5, the wedge regime does not exist.

**(iii) Two pipelined bursts + tail + interleaved single.** Bursts A (ids 16..31) and B (0..15, wraps)
interleave slot-exact writes into ROB0 — no ranges are matched anywhere, so overlap/wrap is a
non-issue (meta_id is absolute). A tail (legacy port-0 singles into ROB0) follows the burst region
after the pending drain; a scalar single (port 0, `core_id 0`) never enters any of this machinery.

## 8. Hazards

### 8.1 The Option-A matmul wedge: ROOT-CAUSED — local-target contract violation (this design is immune)
Full-chain instrumented tracing (VT-Q/VT-P at the VLSU + WT-Q/A/B/D at the MSHR, group-disambiguated)
pinned the shipped design's matmul freeze definitively:

**Mechanism.** A flagged (beat-spread) burst whose target line is in the core's **own group** never
reaches the group MSHR — the intra-group local path serves it with the **legacy contract** (all 16
beats to the original core port, `meta_id = base+b`, ~4-cycle latency, observed as contiguous
port-0-only push runs `wid 16..31` / `24..31,0..7`). The VLSU, having flagged the burst, pre-allocated
the **spread layout** (evens ROB0 `base..base+7`, odds ROB1 `aux..aux+7`). The legacy delivery writes
ROB0 `base..base+15`: mis-placed data in its own even slots, **clobbers the adjacent burst's slots**
(the observed real `DUP_ALLOC`s), and **ROB1's pre-allocations are never written** → `mem_pending[1]`
never drains → the instruction never retires → core frozen (`hv1=0`, `cc0=0`, `mp={16,16}`).
Matmul hits it because B is sharded across all 16 groups (every core periodically loads a B-line
local to its group, near-simultaneously in the lockstep kernel — hence the group-wide freeze at
cyc ~12k); every microbench passed because they all target `REMOTE_G` from group 0 — never local.
Eliminated en route (by the same traces): response-path HoL (zero port stalls, both parities flowed
symmetrically), premature entry dealloc (all deallocs were legitimate same-cycle final drains), MSHR
same-address pileup (16-core same-line repro completes).

**Why ParityDrain+TwinROB0 is immune by construction.** There is only ONE contract: every burst keeps
one contiguous ROB0 range and `meta_id = base+b` end-to-end. A local burst's legacy delivery (all
beats on port 0) writes exactly the correct ROB0 slots; the odd-expected bitmap clears on any
consuming push from either port (§5.3 — the same funnel path that covers MSHR-bypassed bursts);
the dual-head commit simply reads pairs that both arrived via port 0. Local bursts degrade to
1-wide delivery (they never had 2 resp ports anyway) with zero correctness exposure. The wedge class
— a delivery-vs-preallocation contract mismatch — cannot exist when there is no second contract.

**Interim note for the shipped Option A** (if it is exercised before this design replaces it): the
one-line hotfix is to gate `mem_beat_spread` on the target being REMOTE (the VLSU has the address);
without it the opt-in knob is broken for any workload touching group-local lines.

### 8.2 Bounded perf dips (not bugs)
NoC beat reordering can put two same-parity beats in the 2-slot window → 1-wide cycles until order
recovers (`RespBufWords=4` is the cheap mitigation if measured); bypass steals a port with strict
priority; a local/soc response can beat a retagged beat at the shim rr-arb. All bounded.

### 8.3 Classifier invariant is a dependency, not a structure
It rests on op-queue serialization (`vlsu:448-452`). If Spatz ever pipelines a second mem instruction
into the FSM, expected-odd bits and ROB1 allocations can alias — the assertions in §5.3 are the
tripwire; the dependency is documented in the VLSU header.

### 8.4 Bypass bandwidth cliff
An MSHR-bypassed burst (bank-full mergeable miss) delivers 1-wide on port 0 — correct (classifier
clears on any consuming push) but a hidden cliff under MSHR pressure; add a stats counter.

## 9. PPA

Adders and small muxes only: parity = `boff[0]`; retag = conditional 3-bit +1; drain window select =
2:1 mux from `rd_ptr`. **No barrel shifter, no CAM, no per-sub dual-base storage.** Entry net −6+8 =
+2 bits × 64 entries. ROB0 gains one slot-addressed write mux (32×32b FF array) + one extra 32:1 read
mux + a constant +2 pointer increment; ROBs 1–3 and stores elaborate bit-identically. MSHR deletes
the pre-pass + atomic-fire cross-gating (net logic ↓). Watch item: the drain always_comb was already
the module's critical path — re-check synthesis timing at 2-wide.

## 10. Verification plan

1. OFF (`group_mshr_drain_beats` unset): bit-identical netlist claim — compile + `sp-mshr-burst-test`
   PASS + microbench cyc=3954 reproduced.
2. ON: `sp-mshr-burst-test` PASS (data-checked); distinct microbench ≥ shipped 1.27× (expect same or
   better — no atomic-fire idle); same-address 1/4/16-core complete.
3. **Matmul regression (the decisive one): `sp-fmatmul-opt-burst-merge` ON must COMPLETE with kernel
   cycles ≈ OFF (4453) or better, with `[GroupMerge]` confirming B-line coalescing is restored.**
4. Cross products: id-wrap bases (B near 31), two pipelined bursts + drain interleave, multicast ×
   parity × bypass contention, burst+tail with/without `switch_to_tail`, load→store switch with
   in-flight odd beats, **and LOCAL-target bursts interleaved with remote ones (the Option-A wedge
   scenario, §8.1): a microbench sweeping a B-row-like walk across ALL groups including the core's
   own — must complete with correct data on both the local (1-wide, port 0) and remote (2-wide)
   segments.**
5. CMS scoreboard retrained first (expects beat `b` on port `q` or `q+(b%2)`, same meta_id) — else
   false ORPHAN floods mask real failures.
6. Spyglass lint on the touched RTL (synthesizability gate).

## 11. Rollout

Same opt-in surface (`group_mshr_drain_beats=2`; default off, bit-identical legacy). Replaces the
shipped Option A in place; the Option-A commits remain in history with this doc superseding
`respbw_2wide_design.md` (banner added there). If the matmul regression (§10.3) shows ON ≈ OFF with
coalescing restored, the default can be revisited — that decision is explicitly out of scope here.
