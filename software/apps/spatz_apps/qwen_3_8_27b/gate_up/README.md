# Gate/Up streaming projections

This app computes two independent projections, Gate and Up, from FP16 X/weights
into FP32 outputs. It does not implement SiLU, Down or a full FFN. The same
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
four are padding. Two 32-row weight buffers occupy 2.25 MiB. FP32 accumulators
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

The code uses `vfwmacc.vf`: FP16 storage and FP32 arithmetic for every product.
The current RTL widening helper has a known static-review issue converting zeros
and special values. GVSoC implements floating-point conversion differently.
GVSoC correctness therefore does **not** establish this instruction path's RTL
correctness; resolve that separately before claiming RTL validation. No fallback
to lower accumulation precision is made.

GVSoC runners, full numerical/work/CSR validation, bounded telemetry processing,
and offline dashboards are in `TeraNoC_gvsoc/gvsoc/scripts/qwen_gateup/`, reusing
`scripts/qwen_stream/` for execution and the common compound-operator renderer.
The campaign `qwen_gateup_20260917` retains measured comparisons and limitations.
Useful peak for this widening kernel is four FP32 FMAs per core per cycle.
