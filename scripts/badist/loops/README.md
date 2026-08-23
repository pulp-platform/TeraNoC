# Session-owned maintenance loops

These run as Claude `Monitor` tasks, which are **session-scoped**: a session restart kills every
one of them. The badist fleet controllers are NOT affected — they are detached (`ppid=1`, own
session id) and keep dispatching, and the simulations themselves run on remote nodes.

So a restart loses the *supervision*, not the work. Nothing is destroyed by not restarting them;
the campaign simply stops self-healing, results stop being collected, and the artifact goes stale.

## Restart after a session restart

Start each with the `Monitor` tool (persistent), one per loop:

| script | what it does | cadence | notes |
|---|---|---|---|
| `s8_results_loop5.sh` | rescrape results.tsv + mesh JSON, signal republish | on change | **v5** — v4 read the mesh JSON from the old `/tmp` path |
| `s8_campaign_watch2.sh` | campaign counts; problems immediately | periodic | |
| `auto_resubmit_loop.sh` | requeue failed arms (cap 3/arm) | periodic | silent unless it acts |
| `rescue_loop.sh` | rescue arms nothing is dispatching | periodic | now gated on licence headroom |
| `dedup_loop.sh` | kill duplicate running copies | periodic | keeps the copy with more progress, skips dead nodes |
| `heal_loop.sh` | heal stuck/wedged arms | periodic | |
| `topup_loop.sh` | keep both pools at their reserve lines | 10 min | Questa 10 free, VCS 5 free |
| `salvage_loop.sh` | recover results from untracked sims | 30 min | silent unless it recovers |
| `scratch_guard_loop.sh` | node-local disk guard | 20 min | prevents `packaging failed` |
| `fleet_fetch_loop.sh` | fetch delivered results | periodic | |
| `bp_sweep_watch.sh` | backpressure sweep watcher | periodic | separate from the 8×8 campaign |

## State these loops keep outside the repo

`/tmp/claude-620771/` is the OLD session's scratchpad and holds the rescue ledger
(`rescue_ledger.json`, which enforces the 3-rescues-per-arm cap) and the topup arm lists. The
directory survives a restart because it is under `/tmp`, but the next session gets a *different*
scratchpad path. If the old directory is gone, the rescue counts reset to zero — harmless, but the
cap stops protecting arms that already burned their attempts.

## Do not

- Edit a loop script while it runs: bash re-reads by byte offset, and patching a live runner has
  killed a 4-hour arm here. Copy to a new filename and restart the monitor (that is why the results
  loop is `v5`).
- Restart `bp_sweep_watch.sh` blindly — confirm the bp sweep is still live first.
