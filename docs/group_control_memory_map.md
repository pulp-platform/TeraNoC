# Group control outside physical L1

Group barriers and MSHR configuration CSRs use a separate group-local control
aperture. Physical L1 SRAM no longer loses its last 16 words per bank.
Software using these controls must be rebuilt together with the changed RTL:
old barrier addresses now access ordinary SRAM.

## Address map

With the default `group_barrier_word=240`, addresses are inclusive:

| Region | 4×4 (`terapool_spatz4_fpu`) | 8×8 (`terapool_spatz4_fpu_8x8`) |
|---|---|---|
| Physical L1 | `0x00000000–0x003FFFFF`, 4 MiB | `0x00000000–0x00FFFFFF`, 16 MiB |
| Sequential stacks, 512 B/core | `0x00000000–0x0001FFFF`, 128 KiB | `0x00000000–0x0007FFFF`, 512 KiB |
| Interleaved L1 | `0x00020000–0x003FFFFF`, 3.875 MiB | `0x00080000–0x00FFFFFF`, 15.5 MiB |
| Group control | `0x203C0000–0x203FFFFF` | `0x20F00000–0x20FFFFFF` |

Static application/runtime objects and allocator overhead consume part of the
interleaved region. DMA buffers must still be reserved by the application;
the full physical memory range is not an allocation of that size.

The control aperture retains the existing field encoding, with a separate
`GROUP_CONTROL_BASE=0x20000000`:

```
control_address = GROUP_CONTROL_BASE
                + (GROUP_BARRIER_WORD + index) * WORD_STRIDE
                + group * GROUP_STRIDE
                + tile * TILE_STRIDE
                + op * 4

TILE_STRIDE  = 4 * banks_per_tile
GROUP_STRIDE = TILE_STRIDE * tiles_per_group
WORD_STRIDE  = GROUP_STRIDE * groups
```

Indices 0–15 select barrier structs, or MSHR CSRs when `op=3`.
The existing operations remain: barrier arrival load at op 0, target store at
op 1, mask store at op 2, and CSR read/write at op 3. Accesses must address the
caller's own group. Any tile field in that group is valid, including the
caller's tile. Other groups and addresses outside the aperture follow the SoC
address path; they are not remote barrier operations.

The aperture uses mask decoding, so its index count must be a power of two
and its base word must align to that count. Elaboration guards enforce these
constraints and consistency with the tile decoder. `group_barrier=0` removes
control routing and leaves all physical L1 available.

## RTL structure and PPA limits

The tile address map sends control requests through TCDM_EXTERNAL even for an
own-tile target. A `group_ctrl` bit accompanies the request through the existing
crossbar and spill register. The group interconnect selects its control port
from this registered bit, replacing the SRAM-word range comparisons. SRAM
loads, stores, AMOs, vector bursts, and DMA accesses retain their data paths.
The selector is not encoded into NoC packets.

There is no added pipeline stage or change to barrier state/release logic.
The tile adds a constant-mask address rule and the request transport carries
one extra bit. Timing and area impact require backend measurement; functional
validation alone does not establish a PPA improvement.

## Focused validation

`software/apps/spatz_apps/l1-group-control-test/main.c` DMA-fills the last L1
word slice, then reads its banks through own-tile, same-group different-tile,
and different-group paths. It accesses MSHR status and runs two deliberately
skewed barriers using own-tile control targets. The DMA source is preloaded
in L2 and MSHR holding is disabled through the new control aperture so setup
and benchmark merge windows do not dominate the test. Success prints
`[L1CTRL]` with `errors=0`; rendezvous statistics must be nonzero.

`hardware/tb/group_control/tb_group_control_decode.sv` tests the production
tile decoder at every group/tile. It covers all formerly reserved SRAM words,
control operations, aperture boundaries, rejected cross-group controls, L2,
and peripheral addresses. The clock stays stopped: this bench checks routing,
while the application checks state and response behavior.

Run the decoder against an already compiled RTL library in an independent
library, so it does not wait on a full-system elaboration lock:

```sh
hardware/tb/group_control/run.sh decode \
  hardware/build_group_control_4x4 hardware/build_group_control_decode_4x4
hardware/tb/group_control/run.sh decode \
  hardware/build_group_control_8x8 hardware/build_group_control_decode_8x8
```

The focused application builds with:

```sh
make -C software/apps/spatz_apps l1-group-control-test \
  config=terapool_spatz4_fpu -B
make -C software/apps/spatz_apps l1-group-control-test \
  config=terapool_spatz4_fpu_8x8 -B
```

Copy each resulting ELF to its private build directory before rebuilding the
other configuration. Full-system simulation commands and verified results
are recorded below.

## Validation record (2026-09-17)

- Normal Questa RTL compilation passed for 4×4 and 8×8.
- Production RTL compilation with `TARGET_SYNTHESIS` passed; simulation
  testbench sources were excluded from this check.
- Decoder checks passed: 26,112 at 4×4 and 104,448 at 8×8. The 4×4
  `group_barrier=0` decoder also passed 26,112 checks.
- Transport checks passed in group 15 at 4×4 and group 63 at 8×8:
  recovered SRAM data matched, CSR status was zero, 32 arrivals completed
  two rendezvous (`bar_rel=2`), and no response preceded the final arrival.
- `python3 software/tests/gemm_config/test_config.py` passed 40
  shapes/configurations and four rejection checks.
- Focused application ELF builds passed for both meshes.
- The 4×4 full-system run returned zero: DMA populated the final 16 KiB
  L1 slice at `0x003FC000`, the application reported `errors=0`, and the
  two barrier rounds produced 32 group releases (16 per round).
- The 8×8 full-system run is still in progress. Its private transcript is
  `hardware/build_group_control_8x8/transcript`; no full-system pass is
  claimed until its `[L1CTRL] errors=0` and successful exit are verified.

The transport bench can be reproduced using the same independent-library
runner:

```sh
hardware/tb/group_control/run.sh transport \
  hardware/build_group_control_4x4 hardware/build_group_control_transport_4x4
hardware/tb/group_control/run.sh transport \
  hardware/build_group_control_8x8 hardware/build_group_control_transport_8x8
```

The broadcast rendezvous count is `bar_release_cnt_dbg`; the existing
`[GBAR] releases` debug counter counts only the legacy response path and
remains zero with broadcast releases. The transport bench explicitly checks
the rendezvous count rather than treating that legacy counter as coverage.

Full-system runs use private absolute preload paths and waveforms. These
commands name the already optimized private images and load the SRAM-test
DPI library; DRAMSys is not instantiated in these SRAM configurations:

```sh
make -C hardware simc config=terapool_spatz4_fpu \
  buildpath=build_group_control_4x4 top_level=_opt1 questa_voptargs=-O4 \
  questa_args='+PRELOAD=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware/build_group_control_4x4/l1-group-control-test-final.elf -sv_lib work-dpi/mempool_dpi -work work -suppress vsim-12070' \
  -o compile -o clean-dasm

make -C hardware simc config=terapool_spatz4_fpu_8x8 \
  buildpath=build_group_control_8x8 top_level=_opt questa_voptargs=-O4 \
  questa_args='+PRELOAD=/usr/scratch/fenga1/zexifu/TeraNoC_Spatz/TeraNoC/hardware/build_group_control_8x8/l1-group-control-test-final.elf -sv_lib work-dpi/mempool_dpi -work work -suppress vsim-12070' \
  -o compile -o clean-dasm
```

`-o compile` uses the already compiled private libraries. The 4×4 compile was
`make -C hardware compile config=terapool_spatz4_fpu
buildpath=build_group_control_4x4 -o update-floogen -o update_opcodes`, using
existing verified 4×4 generated routing files. The 8×8 Bender compile script
was generated for `terapool_spatz4_fpu_8x8`, with generated-file paths replaced
by `hardware/build_group_control_8x8/generated/` before compilation. Its NoC
package and route table were generated from the 8×8 YAML, and its perimeter
map was generated for 8×8, without replacing shared routing files.
