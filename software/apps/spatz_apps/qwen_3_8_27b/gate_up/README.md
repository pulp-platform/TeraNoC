# Gate/Up streaming projections

This app computes two independent projections, Gate and Up, from FP16 X/weights
into FP32 output storage. Accumulation defaults to FP32; native FP16 is an explicit
experimental option. It does not implement SiLU, Down or a full FFN. The same
sources support the 4×4 and 8×8 Spatz configurations. This is synthetic-data
software development; it is not a pretrained-model deployment.

Builds are isolated: `build.py` copies config/runtime/app sources to a new output
folder, packs inputs in DMA order, computes full logical references, and records
source/ELF hashes, compiler commands, stack frames and linker headroom. It never
writes `software/bin` or the common GEMM kernels. Python needs NumPy and
pyelftools; the current toolchain paths are resolved from this checkout.

```sh
python3 build.py --out /ABS/NEW_ARM --mesh 4 --batch 1 \
  --hidden 5120 --intermediate 17408 --kt 32 \
  --x-replicas group --barrier group
```

The full experiment allocates 512 MiB modeled L2 SRAM. Match that capacity and
the new `GROUP_CONTROL_BASE=0x20000000` map in the simulator. Gate and Up have
different weights and each input row is used unchanged by both projections.
All copies use real target DMA, including optional X replication.

At B1/4×4 each core owns 68 real outputs, packed as 32+32+8 halfwords. The last
four are padding. Two 32-row weight buffers occupy 2.25 MiB. Default FP32 accumulators
stay in vector registers across each K tile, and the same partial-sum allocation
persists across all tiles. Compact outputs are stored separately for validation.
Every weight load begins at a 16-byte-aligned address; full mesh-stripe buffer
alignment also preserves local P0/P1 access in the B1/4×4 layout.

At B1/8×8 each core owns 17 outputs, padded to 24. This has larger padding and
different bank/tile mapping. It is a functional baseline, not a claim of optimal
8×8 packing. Linker capacity is checked for every shape; full outputs and input
replicas can make larger batches exceed L1, requiring explicit row/output staging.

For other batches compare:

- `--distribution shared --rows 2` or `--rows 4`: all cores split columns; each
  loaded weight vector updates several input rows before the next weight load.
- `--distribution split --rows 1`: core teams own different rows and share the
  stored weight matrix. This changes locality and repeated loads.

`--rows` must divide batch. Group input copies and the group/leader barrier
are the defaults; row reuse defaults to one for the batch-1 starting point. `--x-replicas one` and `--barrier flat` retain the
initial baseline. Group replication uses an odd number of group-address stripes
between X copies. The group barrier first gathers local readers, then one leader
per group joins the global atomic rendezvous. All cores wait for the global
wake-up before a staging buffer can be reused. Initial DMA fill, replication,
barriers and final output stores are included in benchmark time.

MSHR admission is enabled with single/burst targets 1 and reuse target 0, so
these classes bypass retained merging. Old GEMM sharing targets are inappropriate
for distinct per-core weight slices. Programmed CSR values/status are recorded.

The default uses `vfwmacc.vf`: FP16 storage and FP32 arithmetic for every product.
The current RTL widening helper has a known static-review issue converting zeros
and special values. GVSoC implements floating-point conversion differently.
GVSoC correctness therefore does **not** establish this instruction path's RTL
correctness; resolve that separately before claiming RTL validation. No fallback
to lower accumulation precision is made.

`--accumulator fp16` explicitly selects native `vfmacc.vf`, with FP16 rounding
after every fused multiply-add across the entire K reduction. Partials are
loaded/stored as FP16 between tiles; final results are converted to FP32 output
storage without recovering lost precision. Its arithmetic peak is eight FMAs
per core per cycle, versus four for widening FP32 accumulation. The weight
packing, real DMA overlap, work assignment and barriers are unchanged.

For controlled comparisons, this option retains the FP32 scratch allocation size
and all L1 buffer bases. A local FP16 accumulator occupies one 64-byte stripe;
the remaining reserved space is unused. This initial option does not claim L1
capacity savings from compacting the allocation. Baseline FP32 generated kernels
remain byte-identical with their original settings.

The builder generates both FP32 and native FP16 references from the logical
unpacked operands. Native FP16 validation checks the whole output against its
own once-rounded FMA reference, then separately reports error against FP32.
Passing the arithmetic check does not establish application/inference accuracy.
`--values dense` uses bounded random FP16 values with more significand bits;
the default small-integer `grid` inputs can hide accumulation error. The focused
`--pattern fma` case checks a cancellation residual that non-fused arithmetic
would round away. Zero/unit/repeated tests remain available.

`--platform-source /ABS/FROZEN/source` reuses an existing arm's config/runtime
sources while compiling the current app. Use it when isolating precision changes
from concurrent platform changes; the selected root and source hashes are recorded.

GVSoC runners, full numerical/work/CSR validation, bounded telemetry processing,
and offline dashboards are in `TeraNoC_gvsoc/gvsoc/scripts/qwen_gateup/`, reusing
`scripts/qwen_stream/` for execution and the common compound-operator renderer.
The campaign `qwen_gateup_20260917` retains measured comparisons and limitations.
Useful peak for this widening kernel is four FP32 FMAs per core per cycle.

`--x-tile local` is an optional diagnostic for KT32. Each core copies the current
32-element X slice into its own 64-byte bank stripe before computing, reusing the
allocation across outer batch row blocks. It costs 16/64 KiB per reused row on
4×4/8×8; the copy and fence are inside the measured compute span. Numerical and
repeated-buffer tests pass on both meshes, but the measured short B1/B4 cases
were 2.6–3.7% slower than group X copies alone. The default remains `off`.

`--tail-width 32` separately pads the final output segment to a full vector.
At B1/4×4 it raises the double weight buffer from 2.25 to 3 MiB and the packed
weight pair from 360 to 480 MiB. It improves the measured full-size run but
reduces L1 headroom, so width 8 remains the baseline. Full-size B1/8×8 with width
32 would need 640 MiB of source weights and is rejected by the current target.

Three optional scheduling/layout controls retain the original settings for
matched comparisons:

- `--partial-layout local` stores each 16-float half of an accumulator in a
  separate core-local 64-byte stripe. Loads/stores use the individual vector
  register halves; arithmetic still uses FP32 widening accumulators. The scratch
  allocation is unchanged. This currently requires `--distribution shared`.
- `--vset-policy hoist` moves vector configuration outside the K loop when a
  register block has identical segment widths. For mixed widths it removes
  adjacent redundant configurations while preserving changes at the tail.
- `--weight-registers separate` gives each segment a distinct weight register,
  reducing reuse dependencies between segment loads. A single-segment block
  generates the same register assignment with either setting.

The comparison defaults remain `linear`, `each-segment`, and `shared` respectively.
The tested 4×4 B1 tuning recipe adds the following to the full-size command above:

```sh
--tail-width 32 --partial-layout local --vset-policy hoist --weight-registers separate
```

Full-size and short correctness/performance results are recorded in the GVSoC
campaign report. Local partial sums are also tested on 8×8 and with two/four-row
reuse. Do not infer full-size 8×8 performance from those short tests: the current
24-element weight packing remains predominantly nonlocal despite valid bursts.
