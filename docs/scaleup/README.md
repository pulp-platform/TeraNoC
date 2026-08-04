# Scale-up documentation

Docs for scaling the cluster beyond the 4×4 / 256-core `terapool_spatz4_fpu`
config that the MSHR campaign was tuned on — larger mesh, more groups, more
cores, more L1, with the L2 (AXI) NoC and the software scaled to match.

The goal is a **configurable** mesh, so the FPU-utilisation and total-compute
curve can be measured across the whole ladder, not a single larger design point.

| doc | what it covers |
|---|---|
| [mesh_plan.md](mesh_plan.md) | The plan: scaling ladder, blockers per subsystem, phase order, software impact, measurement method, open decisions. |

## Start here

`mesh_plan.md` §1 is the part worth reading before anything else — it explains
why the mesh dimensions must be powers of two (the group index is an address
bit-field that is bit-cast into mesh coordinates), and why holding cores/group at
16 keeps the entire group-level microarchitecture invariant across every rung of
the ladder.

## Related, outside this folder

* `docs/benchmarks/` — the 4×4 results this scale-up is measured against, and the
  shape/knob derivation rules that carry over.
* `hardware/ARCHITECTURE.md` — file:line-anchored map of the datapath; read
  before tracing any of the blockers.
* `docs/teranoc_architecture.md` — formal spec with diagrams, including the NoC
  and MSHR microarchitecture.

## Status

Proposal under review. Nothing implemented. See the phase table in
`mesh_plan.md` §4 for the intended order and the gate on each phase.
