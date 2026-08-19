# Patches held here for durability

These are RTL fixes that live in repositories **outside** this tree (notably
`working_dir/spatz`, which `Bender.local` overrides into the build in place of
`hardware/deps/spatz`). They are kept here so the work is not lost if a working
directory is reset, and so the reasoning travels with the diff.

Applying one is the owner's call — nothing here is auto-applied.

## `spatz_vfu_ew_tag_hazard.patch`

**Status: uncommitted in `working_dir/spatz` (branch `zexin/teranoc_burst`) as of 2026-08-19.**

Fixes the fp16 hang. `spatz_vfu.sv:141` selected on `result_tag.wb` — the instruction whose result
is at the FU output — but read the element width from the *live* `spatz_req`. With
`spatz_ipu Pipeline=1` those are different instructions. Snitch has no multiplier
(`snitch.sv:1043-1046` offloads `MUL`), so every `mul` is a VFU scalar op at `EW_32` (mask `4'hf`,
lane 0 only); an `e16` op behind it makes the result be judged against `8'hff`, and
`&(result_valid | ~pending_results)` is false forever.

The functional change is one word — `result_tag.vsew` instead of `spatz_req.vtype.vsew`. The tag
already carried `vsew` (`:52`, captured at issue `:539`); it simply was not used. The rest of the
diff is the explanatory comment.

Verified by controlled A/B (`software/apps/spatz_apps/sp-vfu-ew-tag-probe`), verdicts
pre-registered including the refuting outcomes:

| phase | unfixed | fixed |
|---|---|---|
| A — e16 alone, no `mul` | passed | passed |
| B — `mul` + e32 | passed | passed |
| C — `mul` + e16 | **HUNG 256/256**, `raw` 256000/256000 | **passed**, `ALL_PHASES_DONE`, Errors: 0 |

Full write-up: `docs/fp16_matmul_deadlock.md`.
