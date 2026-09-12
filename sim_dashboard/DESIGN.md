---
type: decision
status: accepted
decided: 2026-09-10
---
# Offline simulation dashboard architecture

The user chose offline HTML for the first delivery, RTL GEMM as the first source,
and both aggregate and individual-entry MSHR views. They also requested hash
allocation analysis and the existing hierarchical roofline. All new files belong
in `sim_dashboard/`, keeping existing scripts, RTL and software untouched.

Python adapters normalize evidence into a shared schema, leaving a future GVSOC
adapter independent of the frontend. HTML embeds compressed data and all assets.
This is easy to open and share; a local server and live tailing were deferred.
The tradeoff is that decoded records must fit in Python/browser memory.

FPU activity measures busy lane-cycles. Workload progress requires completed
FMACs and the actual expected group assignment; activity alone cannot establish
completion. Missing probes remain unavailable. Counter windows preserve their
actual spans instead of being interpolated across unsupported time boundaries.

Hash candidates are conditional modeled alternatives ranked by concurrent bank
spread within supported settings. They are not simulated performance results.
Roofline intensity must use bytes from the matching boundary and workload window;
legacy partial coverage is explicitly estimated. Correctness is reported
separately and never inferred from speed or utilization.

The optional RTL probe is integrated through an instrumented TB copy. Its
accounting is exercised in a miniature Questa hierarchy; a full instrumented
GEMM still needs to validate real hierarchy elaboration and workload totals.

The attempt to additionally store this decision in Basic Memory failed with a
SQLite vector-index read error. This local decision is the durable fallback.
