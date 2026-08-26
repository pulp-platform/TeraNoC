# Quiescent-deadlock evidence archive

Full QuestaSim/VCS transcripts of the 17 arms retired on 2026-08-26 as **quiescent deadlocks**,
zstd-compressed on the compute node and written straight here. **12.6 GB raw -> 146 MB.**

These are the primary evidence for the failure class described in `../quiescent_deadlock.md`.
The arms were killed after archiving, so these files are the only surviving copy: badist would
have reclaimed the node-local run dirs, and the previous `hardware/s8_<arm>/transcript` copies
were **stale partials from earlier attempts** with 171-642 `[FPU] bench` samples, two of which
would not even have classified. The archived copies carry 764-4,638 samples each.

## Reading one

```sh
zstd -dc fp32_2048x32x256.transcript.zst | sed 's/^# //' | grep -a '\[FPU\] bench' | tail -5
zstd -dc fp32_2048x32x256.transcript.zst | grep -a 'STUCK_REQ' | tail
```

⚠️ QuestaSim prefixes every line with `# `; strip it before any anchored match.

## What every one of them shows

- `busy=0/4096000` lane-cycles on the last `[FPU] bench` line — every FPU lane idle, all 64 groups
- `RH STUCK = 0` and `mshr_timeout=+0` in **both** the `pre` and `bench` phases
- `bar_rel=+0` with `bar_max` static — arrivals accumulated at the group barrier, never released
- `[BP] hsk=0 stall=0 idle=...` — links idle rather than blocked
- `[CMS WARN] STUCK_REQ` in an early burst that then stops, while the run continues for millions
  of further cycles

## The specific request to trace

`fp32_2048x32x256`, hart `0x202` (group 32, tile 2), shared scalar port:

```
cyc=21000 STUCK_REQ g=32 t=2 p=0 hart=0x202 id=0 age=1053 addr=0x00f880c0 R bl=1 beats=0
cyc=33000 STUCK_REQ g=32 t=2 p=0 hart=0x202 id=0 age=1935 addr=0x00f880c0 R bl=1 beats=0
```

Same `id`, same address, `beats=0`, age growing. `0x00f880c0` decodes to group 0, tile 12.
That hart's last instruction retired at cycle 31,064 — the cycle the request started.

**A waveform following this request** from the tile port through the group MSHR to the NoC and
back is what distinguishes the three candidate mechanisms (response dropped in the NoC; MSHR entry
completing without arming its timeout; request never reaching the MSHR).
