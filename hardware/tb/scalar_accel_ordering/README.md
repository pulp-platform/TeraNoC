# Scalar/accelerator memory ordering

`EnScalarAccelMemOrdering` defaults to `0`. Snitch integer loads/stores may
issue while accelerator memory instructions are outstanding. Software must
order dependent accesses explicitly, including synchronization and MMIO whose
meaning depends on earlier accelerator memory operations.

Set `en_scalar_accel_mem_ordering=1` in the hardware make invocation or a config
file to restore the previous automatic interlock. Recompile RTL after changing
this setting; use a fresh build path to avoid reusing a previous configuration.

The setting propagates through `EN_SCALAR_ACCEL_MEM_ORDERING`, `mempool_pkg`,
`mempool_tile`, and the active `working_dir/spatz` core wrapper to Snitch.
The implementation also changes vendored `hardware/deps/snitch/src/snitch.sv`.

Both modes retain the outstanding-operation counter limit, register hazards,
LSU backpressure, and explicit fences. `fence` waits for integer LSU and
accelerator memory completion. This platform's custom `sfence.vma` waits only
for accelerator request issue, not completion. AMOs decoded as scalar loads
are affected by the same optional ordering check. Physical port, bank, and
network contention remain.

## Focused validation

Run from the repository root:

```sh
python3 hardware/tb/scalar_accel_ordering/run.py
```

This instantiates the real Snitch RTL with a mocked accelerator completion
interface. It checks all four vector/scalar load/store combinations at distinct
addresses, scalar backpressure, counter saturation and recovery, request-sent
fences, full accelerator completion fences, and integer store acknowledgement
fences, with ordering both disabled and enabled. The runner requires a PASS
marker and rejects simulation errors/fatals.

Build directory: `hardware/build_scalar_accel_ordering`.
Logs: `ordering_0.log`, `ordering_1.log`; waves: `ordering_0.wlf`,
`ordering_1.wlf`. Key signals are `tb.dut.acc_mem_stall`,
`tb.dut.acc_mem_cnt_q`, `tb.dut.acc_mem_str_cnt_q`, `tb.dut.lsu_qvalid`,
`tb.dut.fence_stall`, and `tb.data_valid`.

Both modes passed on 2026-09-20. Full RTL source compilation also passed with
this exact command:

```sh
make -C hardware config=mempool_spatz4_fpu \
  buildpath=build_scalar_accel_ordering_compile \
  lib build_scalar_accel_ordering_compile/compile.tcl
```

No full-system `make simc` run or performance benchmark was performed.
