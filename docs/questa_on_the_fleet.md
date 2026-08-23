# QuestaSim on the badist fleet — what it takes to make it work

Written 2026-08-22 from getting an 8x8 Questa arm running end to end. Everything here was
measured, not assumed; several points contradict what the code comments say.

**Why bother:** VCS has **100** runtime seats, Questa **400**. When a sweep saturates VCS, Questa
is the only way to keep the fleet busy. It is the slower path — use it for small shapes.

---

## 1. The blockers, in the order they bite

### 1.1 `questa-2023.4-zr` is not on the fleet's PATH — rc=127 on every node

badist runs jobs in a **non-login shell** whose PATH is
`/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin`. `/usr/sepp/bin` is **not** on it, so a bare
`questa-2023.4-zr` fails with `command not found` on **every** node — badile, larain and fenga
alike (verified). The binary is present at `/usr/sepp/bin/questa-2023.4-zr` everywhere.

**VCS never hit this** because its spec runs the elaborated `mempool_simvopt` **by absolute path**
and needs nothing on PATH. That difference is the whole reason Questa looked broken and VCS did not.

Fixed in `scripts/badist/teranoc_fleet.py`: `QUESTA_CMD` is now the absolute path.

### 1.2 The retry loop calls every early exit a licence shortage

The job wrapper treats *any* exit before simulation time 0 as "no licence seat?" and sleeps 300 s,
twelve times. An `rc=127` (command not found) therefore burns an hour of a held slot while
reporting the wrong cause. **Read `stderr.log` in the job dir before believing the licence story.**

### 1.3 The shared `work/` library serialises every arm

`questa_launch()` symlinks ONE `work/` library across all arms — correct for *simulation*, which is
read-only, but **`vopt` WRITES to it**:

- two arms on one node serialised on `work/_lock`, one spinning ~12 minutes;
- each run created its **own** optimised design — `_opt`, `_opt1`, `_opt2` from three runs, roughly
  **2.6 GB each**; the library reached **7.9 GB**;
- Questa does **not** reuse a previous run's optimised design.

Left alone, an N-arm Questa wave elaborates one arm at a time and grows the library by 2.6 GB per arm.

**The fix — pre-elaborate ONCE under an explicit name**, then arms only read:

```sh
cd hardware/build_q_8x8
questa-2023.4-zr vopt -work work work.mempool_tb -o s8_opt -suppress vopt-2880
# then arms run:  vsim ... work.s8_opt   (no vopt, no lock, no growth)
```

### 1.4 A killed Questa leaves a STALE lock that blocks the next arm

Questa does **not** release `work/_lock` when its process is killed; the file keeps the dead pid.
This happened twice in one session — once from a killed local pilot, once from a cancelled fleet
arm — each time blocking a live arm until cleared by hand. Recovery:

```sh
cat hardware/build_q_8x8/work/_lock          # "user@host, pid = NNN"
ssh <host> "ps -p NNN"                       # confirm DEAD first
mv hardware/build_q_8x8/work/_lock /tmp/     # move aside, do not delete
```

### 1.5 `badist cancel` does not stop QuestaSim

It kills the job wrapper; `vsimk` and `voptk2` keep running and keep holding the lock. After
cancelling a Questa arm, kill the processes **by PID on the node**, identifying them via
`/proc/PID/cwd` — the same trap as `pkill` leaving `vsimk` alive.

---

## 2. `simc` vs `simc-lean`, and `+acc`

`hardware/Makefile` records that at 1024 cores `vopt` with `+acc` **"did not finish in 60 minutes"**
and a whole-design `log -r *` WLF would be unusable. Use **`simc-lean`** at 8x8.

`teranoc_fleet.py` passed `-voptargs=+acc` with a comment warning that hierarchical TB probes would
otherwise be optimised away, producing a **silent no-data run**. **Measured: that does not happen
here.** With `+acc` removed, elaboration took **~10 minutes** and every probe still emitted —
`[FPU] [FPUG] [STALLG] [MSHRG] [MEMOG] [INSNG] [CMS] [BYP]` — with correctly-scaled 8x8
denominators (`busy=0/4096000` = 1024 cores x 4 lanes x 1000 cyc), which a stripped net could not
produce.

Keep the gate anyway, because the failure mode would be silent:

```sh
grep -c '^\[FPU\]' transcript     # 0 => probes optimised away, NOT a quiet run
```

---

## 3. Measured numbers (8x8, `512x256x512` fp16, badile, same ELF both simulators)

| | VCS | Questa |
|---|---|---|
| peak RSS | **7.80 GiB** | **16.4 GiB** |
| throughput | **19.4 cyc/s** | **12.2 cyc/s** |
| elaboration | once, at build time | ~10 min **per arm** (until 1.3 is applied) |
| fits a badile (~46 GiB placeable) | yes | **yes** |

**They agree exactly**: `util=14.92%`, `RH=0`, `CMS=4037` on the same ELF — extending the
validated-identical result from 4x4. Either simulator is trustworthy; VCS is simply faster and
smaller.

**A projection that was badly wrong:** I estimated Questa 8x8 at ~60 GiB by scaling the 4x4 figure
by the 4x design. It is **16.4 GiB** — Questa's footprint is not dominated by core count the way
VCS's is (VCS scaled almost exactly: 2.02 -> 7.80 GiB). Do not scale Questa memory linearly.

---

## 4. Dispatching a Questa wave

```sh
scripts/badist/teranoc_fleet.py submit --arms arms.txt --run-prefix q \
    --backend questa --image build_q_8x8 --mem-gb 20
```

- `--mem-gb 20` (measured 16.4 + headroom). The default 4 would pack arms onto nodes that cannot
  hold them. Badiles ARE eligible — the earlier "larain/fenga3 only" claim was wrong.
- Check the pool with `lmstat -f msimhdlsim` (400 seats).
- Apply §1.3 first, or the arms will elaborate one at a time.
