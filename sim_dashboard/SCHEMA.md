# Telemetry schema v1

UTF-8 JSON Lines, one object per line. Counters are **deltas over [start,end)**
in core-clock cycles since reset. There are no implicit zero-filled missing
records. Use a fresh file for a new simulation/reset epoch. `phase` is `pre`,
`bench` or `unknown`; explicit phase boundaries should split a window.

A `meta` record has `schema_version: 1` and may supply run-manifest fields:

- `mesh: [NumX, NumY]`, `backend`, `name`
- `tiles_per_group`, `cores_per_tile`, `n_fpu`, `banks_per_tile`
- `mshr_entries`, `mshr_ways`, `req_subnets`, `resp_subnets`
- `shape: [M,N,P]`, `precision`, `repetitions`, `cycles_per_pass`
- `benchmark: [start,end]` for a single timed region
- `expected_fmac_per_group: [integer,...]`, actual GEMM FMAC assignment
- `fmac_reduction_steps`: FMACs per output (defaults to N). Use N−1 for kernels that initialize with FMUL; the initial multiply is excluded from FMAC progress. Roofline FLOPs retain the conventional 2×M×N×P definition.
- `correctness`: explicit status, defaults to `unknown`
- `hash`: see the example manifest and README; modeled inputs, not observations

Every non-meta record has `kind`, integer `start`, `end`, and `phase`.
Group identity is `g = x * NumY + y`; tile and bank IDs are local to that group.

| kind | Dimensions | Measurements |
|---|---|---|
| `fpu` | `g` | `busy` lane-cycles, `capacity` lane-cycles |
| `work` | `g` | `fmac` completed scalar-equivalent FMACs; optional `workload_phase` identifies issuing region |
| `mshr` | `g` | `occupied` entry-cycles, `capacity` entry-cycles, `entries`, `peak` entries, `full` cycles; optional timeout fields as on `entry`, as group totals |
| `entry` | `g`, `entry` | `occupied`, `capacity`, `cached`, `held` cycles; optional `state` at final sampled cycle; optional `timeout_single`, `timeout_burst`, `timeout_subs`, `resp_hold_timeout`, `cache_timeout` |
| `bank` | `g`, `t`, `bank` | `hsk` accepted accesses, `stall` valid-and-not-ready cycles |
| `link` | `g`, `network`, `subnet`, `direction` | `hsk` accepted transfers, `stall` valid-and-not-ready cycles |
| `traffic` | global | `mst_resp`, `slv_resp`: arrays of remote payload word counts per endpoint response port; `mst_req`, `slv_req`: accepted request counts per remote request port (optional in older traces) |
| `stage` | `g`, `label`, `t` (-1 for group) | `hsk`, `stall`, `idle`, `active` cycles; legacy BP adapter |
| `pressure` | `g` | `timeout`, `bypass`; legacy MSHRG adapter |

Entry ID maps to bank `entry // mshr_ways` and way `entry % mshr_ways`.
The optional timeout fields count expiries in the window, attributed to the entry
that expired. `timeout_single` and `timeout_burst` are hold windows that expired
below the subscriber target, classified by the entry's burst length;
`timeout_subs` sums the subscribers present at those expiries, so mean
subscribers at expiry is `timeout_subs / (timeout_single + timeout_burst)`.
`resp_hold_timeout` counts response-hold entries aged out by the serve timeout and
`cache_timeout` cached lines aged out before reaching their reuse target; both are
separate events and neither contributes to `timeout_subs`.
States are 0 free, 1 waiting for response, 2 draining, 3 cached, 4 response hold.
The `held` cycle count is a subset of waiting with `issued == 0`; it is not an
additional occupied entry. Cached cycles are likewise included in occupancy.

`network` is `req` or `resp`. `direction` is 0 north (+y), 1 east (+x),
2 south (-y), 3 west (-x). Each link record describes **one physical output
channel**. The current probe flattens `subnet = tile * ports + port`; request
ports list narrow then wide channels, response ports exclude local port zero.
The same subnet identity is used at each mesh node. Preserve this identity in
new adapters; do not collapse channels with different capacities.

Traffic words are 4 bytes in this RTL. Payload accounting deliberately excludes
wire headers and repeated router hops. Each global traffic window occurs once;
FLOPs and bytes must cover the same interval to form a measured roofline point.

Example (illustrative data, not a simulation result):

```json
{"kind":"meta","schema_version":1,"mesh":[4,4],"backend":"rtl"}
{"kind":"fpu","start":0,"end":1000,"phase":"bench","g":0,"busy":32000,"capacity":64000}
{"kind":"mshr","start":0,"end":1000,"phase":"bench","g":0,"occupied":8000,"capacity":64000,"entries":64,"peak":16,"full":0}
{"kind":"entry","start":0,"end":1000,"phase":"bench","g":0,"entry":0,"occupied":500,"capacity":1000,"cached":100,"held":40,"state":1}
{"kind":"bank","start":0,"end":1000,"phase":"bench","g":0,"t":0,"bank":0,"hsk":400,"stall":100}
{"kind":"link","start":0,"end":1000,"phase":"bench","g":0,"network":"req","subnet":0,"direction":1,"hsk":200,"stall":100}
```

The generator validates time intervals, duplicate identities, group geometry and
basic count bounds. It preserves source line numbers and flags overlapping
legacy windows. It does not turn an unknown counter value into zero or validate
a workload's numerical result from its utilization.

Benchmark compute utilization is workload throughput relative to the declared
precision-specific peak: `(2*M*N*P*repetitions / peak_FLOPs_per_cycle) /
benchmark_cycles`. It is distinct from sampled busy-lane utilization and uses
the explicit CSR benchmark interval when available. The conventional GEMM FLOP
count includes the initial product even for FMUL-initialized kernels.

The hash view's operand sharing degree counts cores assigned the same A row
tile or B column tile within a group. It describes potential same-element
sharing from the partition, not simultaneous issue or observed MSHR merging.

Link network names are normalized for surrounding whitespace when reading
JSONL. Older VCS probes padded `req` to ` req` through a packed-string ternary;
its counts remain valid. New probes use string-typed branches. Phase filtering
matches explicit phase labels; unclassified legacy counters are available under
All phases or Unclassified, and do not extend the benchmark axis.

## Request-class occupancy (optional extension)

`mshr` and `entry` records can carry `occupied_single` and `occupied_burst`.
Both are entry-cycle counts, classified at each sampled cycle using the valid
entry's `burst_len` (1 versus >1), and must sum to `occupied`. Both must be
present together. For group utilization, divide either by the total table
capacity; their fractions sum to total occupancy. Do not classify an entire
window from the type present at its end: an entry can be reused within it.
Missing class counters are unavailable, not zero.

`mshr.single_merge_target` and `mshr.burst_merge_target` capture the effective
RTL target settings at the window end. Target 1 encodes class bypass; global
MSHR disable can also bypass traffic independently of these targets.

The transcript adapter also preserves final `MSHRLIFE-BL` counters as
`meta.mshr_lifetime_classes`, keyed by `x,y`. These are whole-run completed
entry counts and response-drain sums, not per-window occupancy or input
request counts. `software_merge_targets`, when extracted from ELF DWARF by
the campaign validator, are compiled software constants, not CSR readback.
