# Running TeraNoC simulations on the badile fleet

`fenga1` has 96 threads and sits at load ~105 with a sweep on it: every arm gets
about nine tenths of a core, and a 61-arm sweep serialises against itself. The
badile fleet is ~25 idle 12-core Ryzen 9900X desktops with nothing on them. This
document is how we get a sweep onto them.

Two pieces, deliberately separate:

| | what it is | where |
|---|---|---|
| **badist** | the *service* — hosts, jobs, resources, results. Knows nothing about simulators. Written by msc26f31 (`/home/msc26f31/badist`). | `~/badist` (our own copy) |
| **teranoc_fleet.py** | our *client* — what an arm is, how VCS and Verilator are invoked, which licence feature we hold, and where results must land. | `scripts/badist/teranoc_fleet.py` |

`~/badist/README.md` is the service reference and `~/badist/AGENTS.md` is its
"read this before your first submit". This file is only the TeraNoC part.

---

## One-time setup

```sh
cp -r /home/msc26f31/badist ~/badist            # the service; state/ is per-user
export PATH=$HOME/badist/bin:$PATH              # add to ~/.zshrc
badist nodes                                    # fleet health
```

`~/.badist.json` holds our overrides (hosts, gather location, long-job policy).
It is small and already written; the shipped defaults live in
`~/badist/etc/badist.json`.

Results are gathered to `/usr/scratch/fenga1/zexifu/badist-results/<batch>/`.
Never point `gather.dir` under `$HOME` — badist refuses it, and rightly: `$HOME`
is a 50 GB filer with 7.7 GB free.

---

## Running a sweep

```sh
# 1. ALWAYS dry-run first: it validates the spec and reports placement.
scripts/badist/teranoc_fleet.py submit --arms arms.txt --run-prefix run6 --dry-run

# 2. Then for real. Watch mode returns when the batch ends and fetches results.
scripts/badist/teranoc_fleet.py submit --arms arms.txt --run-prefix run6

# 3. Any time, from any machine (the ledger is on $HOME):
scripts/badist/teranoc_fleet.py status
badist status --watch
badist status --by-node

# 4. If you used --no-watch or --deadline, pull results in when they are ready:
scripts/badist/teranoc_fleet.py fetch
```

`arms.txt` is one arm per line, `<name> <elf> [image]`, paths relative to
`hardware/`:

```
16_512x64x256     i2_16_512x64x256.elf
32_256x128x256    i2_32_256x128x256.elf
```

Or drive it straight off the GEMM shape list:

```sh
scripts/badist/teranoc_fleet.py submit \
    --shapes scripts/gemm_sweep_shapes.txt --prec 16 \
    --elf-template 'i2_{prec}_{shape}.elf' --run-prefix run6
```

### Results land where the scrapers already look

Each arm is unpacked into **`hardware/<run-prefix>_<arm>/transcript`** — the same
layout `launch_bp_sweep.sh` produces locally. `gen_fp16_sweep_dash.py`,
`gen_fp16_sweep_html.py` and the watcher scripts work unchanged; nothing
downstream needs to know the arm ran on another machine.

That is the whole point of the `meta` blob: the client attaches
`{"arm": ..., "run_dir": ...}` to every job, badist round-trips it, and `fetch`
uses it to route each tarball home.

---

## Backends

| | `vcs` (default) | `questa` | `verilator` |
|---|---|---|---|
| image | `build_vcs_fix/mempool_simvopt` + `.daidir` (~835 MB) | `build_bp_q/` — a compiled **build directory** | `vbuild_4x4/Vmempool_tb_verilator` (456 MB, one file) |
| invocation | `+PRELOAD=<elf> -l transcript` | `vsim -c -voptargs=+acc … work.mempool_tb` | `--meminit=ram,<elf> \| tee transcript` |
| licence pool | `VCS-Base-Runtime-Pkg`, **100 seats** | `msimhdlsim`, **400 seats** | none |
| measured RSS | **2.0 GB** | **15.9 GB** headless (24 GB with waves) | not yet measured |
| speed | fastest | ~1.7× slower | — |
| mesh | 4x4 and 8x8 | 4x4 and 8x8 | **4x4 only** — fails at 8x8 |

**VCS and Questa produce identical cycle counts** (validated: 91,859 both), so a sweep
that mixes them is still poolable. Verilator has never been validated that way here.

### Falling back instead of waiting

A full VCS pool must not mean an idle sweep. `--fallback questa` puts both simulators
in the *same job*: it runs VCS, and if VCS exits before simulation time 0 — the only
trace a refused seat leaves — it re-runs the same ELF under QuestaSim on the same node.

```sh
scripts/badist/teranoc_fleet.py submit --arms arms.txt --run-prefix run6 --fallback questa
```

Two consequences to know about:

- **`+vcs+lic+wait` is dropped when a fallback is set.** That flag makes a seat-starved
  simv *queue* rather than exit; with a fallback available, queueing is the wrong answer
  and would stop the fallback ever firing. Without a fallback the flag is added, because
  then waiting beats dying.
- **The job is placed for the fallback's footprint.** Questa needs 16 GB against VCS's
  2 GB, so a job that *might* fall back must be admitted as if it will — otherwise the
  fallback lands on a node that cannot hold it. That drops a 62 GB node from ~10 slots to
  3, which is the honest price.

Each result carries a `.sim_backend` file saying which simulator actually produced the
transcript. A mixed sweep whose provenance is not recorded is a sweep you cannot defend.

Building the Questa image (there is no shared one; check the defines against the VCS
image before trusting a mixed sweep):

```sh
cd hardware && make -o update-floogen compile config=terapool_spatz4_fpu \
    buildpath=build_bp_q group_mshr_merge_reqs=16
# then diff the +define+ sets:
for f in build_bp_q build_vcs_fix; do grep -oE '\+define\+[A-Z0-9_]+=?[0-9]*' $f/compile*.* | sort -u; done
```

One compiled library serves every arm: the job symlinks `work/` and `work-dpi/` into its
own directory and copies `modelsim.ini`, so N arms share 1.4 GB read-only while each
transcript, WLF and `trace_hart_*.dasm` stays in its own job directory.

### The licence is the real cap, not the fleet

Our simv holds **`VCS-Base-Runtime-Pkg`**, not the `VCSRuntime_Net` in badist's
README — that feature does not exist on our server. Verify with:

```sh
scripts/badist/teranoc_fleet.py license
lmutil lmstat -c 8169@lic-synopsys.ethz.ch -f VCS-Base-Runtime-Pkg
```

100 seats department-wide, and one long arm holds its seat for hours. When this
was written, 90 were in use (68 by one colleague, 19 by our own local sweep) —
**ten free**. The client therefore ships a governor by default:
`--max-parallel 24` caps our own seats and `--reserve-licenses 20` makes it back
off when the department is busy. Jobs sitting in `pending` because of that are
the governor working, not a hang.

Distributing to badile does **not** create seats. What it buys is a full 4.4 GHz
core per arm instead of nine tenths of a contended one, and it gets the load off
fenga1.

---

## Facts about this fleet worth not rediscovering

- **The repo is visible from every node.** `/usr/scratch/fenga1/...` and `/home`
  are automounted fleet-wide. `/scratch` and `/tmp` are node-local — a path there
  exists only on the machine you are sitting at, and a job pointed at one fails
  everywhere with no error naming the cause. The client refuses any image or ELF
  that is not on a fleet-visible path.
- **The VCS simv is relocatable.** Its RPATH is `$ORIGIN/mempool_simvopt.daidir`,
  so image + `.daidir` copied anywhere still runs — which is what makes
  `teranoc_fleet.py stage` possible.
- **VCS runs on a badile node with no environment setup at all.**
  `/usr/pack/vcs-2024.09-zr` is mounted and the runtime finds its licence without
  `LM_LICENSE_FILE`. Verified by running an arm on badile01 from a bare
  `BatchMode=yes` ssh.
- **Only 12-core nodes are in scope.** `badile01`–`badile49` are the 64 GB Ryzen
  9900X desktops; `badile101`–`badile111` are 2–4 core 16 GB machines and are
  excluded. `suninfo badile` lists them all with their specs.
- **`cload badile` does not work** — the system `cload` only knows tortin,
  mont-fort, attelas, pisoc, design, sassauna, vilan, dolent, gpu. Use
  `badist nodes` (cores, load, free RAM, disk, NIC link, who is logged in) or
  `rup badile01 badile02 …`.
- **Three nodes have 100 Mb links** and one has no writable scratch; placement
  refuses the latter outright and `--min-link-mbps 1000` excludes the former for
  trace-heavy arms. `badist nodes` flags all of them.

## Checking what is running

```sh
scripts/badist/workload.sh          # licences + fenga1 + sweep arms + fleet, all of it
scripts/badist/workload.sh lic      # just the seat pools
scripts/badist/workload.sh arms     # per-arm phase, and what is DEAD
```

The `arms` view is the one that matters. It cross-references the badist ledger, so an
arm dispatched to the fleet is reported as `on-fleet` rather than mistaken for a dead
local run — and a genuinely dead arm (4 KB transcript, no process, untouched for
15 minutes) is called out in red rather than reported as "still loading".

## Being a good guest

These are colleagues' interactive desktops. badist already runs everything at
`nice 5` / `ionice -c3`, reserves 2 cores and 8 GB per node, spreads rather than
packs, refuses busy machines, and drains rather than evicts. What is left to us:

- **Do not fan out trivial work.** A handful of short arms finishes faster
  locally than the fleet takes to place them. Distribution earns its cost on
  multi-hour sweeps.
- **Declare resources honestly.** `badist stats <batch>` prints what the arms
  actually used and a suggested `resources` block; feed it back into the next
  submit.
- **Clean up.** `badist gc <batch>` once results are gathered.

## Staging (optional)

The VCS image plus `.daidir` is ~835 MB on one NFS server. badist measured eight
concurrent cold readers collapsing to 40–71 MB/s each. Before a large fan-out:

```sh
scripts/badist/teranoc_fleet.py stage --warm            # cheap: warm page cache
scripts/badist/teranoc_fleet.py stage                   # copy to node-local NVMe
```

Steady-state it buys about nothing (a warm-NFS job measured −0.5 % versus local
disk); it is the cold start it fixes.

## The failure this was built for

On 2026-08-21 a local 61-arm sweep was launched with every arm fired at once. Only 23
got a VCS seat. The other **38 exited within seconds** with

```
Licensed number of users already reached for VCS-BASE-RUNTIME/VCSRuntime_Net.
Use +vcs+lic+wait to queue for the license.
```

on stderr — which the launcher had sent to `/dev/null`. Each left a 4 KB transcript
holding nothing but the VCS banner, and every tool that infers "still loading" from the
*absence* of an `[FPU]` line reported them as loading for two and a half hours.

Three things in this client come directly from that: the fallback, the retry loop, and
`workload.sh arms` calling a dead arm dead. If you add a new way to launch simulations,
make sure it cannot lose stderr.

## Traps that are silent rather than loud

The client preflights all of these and refuses the submit rather than letting a
sweep produce hours of quietly wrong data:

- an ELF under `software/bin`, which is rebuilt in place — the simulator reads it
  at simulation *time 0*, not at launch, so a rebuild while jobs are still
  starting hands them a different workload with no error;
- an image or ELF on a path the nodes cannot see;
- a VCS image with no `.daidir` beside it;
- two arms with the same name, which would share one run directory;
- a run directory that already has content, which would mix two campaigns in one
  transcript directory (`--force` to overwrite deliberately).
