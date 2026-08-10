# Repository Guidelines

## Project Structure & Module Organization
- `config/` holds shared hardware/software configuration files such as `mempool_spatz4_fpu.mk` and `terapool_spatz4_fpu.mk`.
- `hardware/src/` contains RTL; `hardware/tb/` contains testbenches and DPI glue; `hardware/scripts/questa/` and `hardware/scripts/burst_tests/` hold waveform and regression scripts.
- `software/apps/` contains bare-metal, OpenMP, Halide, and `spatz_apps/`; compiled binaries land under `software/bin/`.
- `software/runtime/` provides linker/runtime support; `software/riscv-tests/isa/` and `software/tests/` hold verification programs.
- Treat `hardware/deps/` as vendored IP: patch only when necessary and keep changes minimal and isolated.

## Build, Test, and Development Commands
- `make -C TeraNoC update-deps` refreshes and patches dependencies after submodule changes.
- `make -C TeraNoC/software/apps/spatz_apps vector-burst-test config=mempool_spatz4_fpu -B` rebuilds a Spatz app.
- `make -C TeraNoC/hardware simc config=mempool_spatz4_fpu app=apps/spatz_apps/vector-burst-test buildpath=build_4 -B` compiles and runs Questa simulation.
- `make -C TeraNoC/software riscv-tests COMPILER=gcc` builds ISA tests; `make -C TeraNoC riscv-tests` runs the broader flow.
- `TeraNoC/hardware/scripts/burst_tests/run_vector_burst_sweep.sh` runs the vector-burst sweep; check its README before long regressions.

## Coding Style & Naming Conventions
- Follow `.editorconfig`: 2-space indentation, LF endings, final newline, 80 columns by default, 100 for `*.sv`/`*.svh`; Makefiles must use tabs.
- C/C++ formatting follows `.clang-format` (LLVM base). Run `make -C TeraNoC format` before submitting broad software changes.
- Preserve existing RTL naming: modules/types in `snake_case`, parameters in `UpperCamelCase`/ALL_CAPS as already used, debug/stat signals suffixed `_dbg`, `_q`, `_d`, `_next` consistently.
- Prefer packed arrays/structs in RTL unless unpacked storage is required by an interface.

## Testing Guidelines
- Validate the narrowest relevant target first: app build, then focused RTL sim, then sweeps.
- **When changing mesh size (`num_groups`/`num_x`), audit software for hardcoded address-field
  shifts.** The L1 byte address is `word | group | tile | bank | byte`, so widening the group field
  moves the word field up: 16 groups → stride 16384, 64 groups → 65536. Derive it
  (`4 * BANKS_PER_TILE * NUM_TILES_PER_GROUP * NUM_GROUPS`) as `software/runtime/arch.ld.c` and
  `sp-fmatmul.c`'s `gbar_base()` do; and recover packed fields with `/` and `%`, not fixed-width
  masks (`hid & 0xF0` drops `group[5:4]` at 64 groups). A wrong constant here does not fail loudly —
  it silently mis-routes. This made the group barrier a no-op for the entire 8x8 campaign.
- **zsh does not word-split unquoted parameters.** `for x in $list` iterates once with the
  entire string; use `while IFS= read -r x; do ... done <<< "$list"`. Fails silently as
  zeros, not as an error. Add `grep -a` when scanning simulator logs.
- **Treat an all-zero telemetry counter as a bug report.** After any barrier or address change:
  `grep -o 'bar_rel=+[0-9]*' <run>.log | sort -u` — all `+0` means the barrier never fired.
- **`software/bin` is global; a rebuild can corrupt a sim that is still elaborating.** Every sim
  preloads the one shared `software/bin/apps/<cat>/<name>` path (`hardware/Makefile:85`), with no
  output-path override, and reads it at simulation **time 0** — not at launch. A run still in
  elaboration picks up whatever ELF is on disk when it gets there, so rebuilding the app for a
  different config in the meantime silently gives it the wrong workload. Check first with
  `grep -aqm1 '\[FPU\] bench' <buildpath>/transcript`; back up and restore the shared ELF around
  the build; preload long runs from a private absolute-path copy (`hardware/matmul_*.elf`).
- For RTL changes, record the exact `make simc ...` command and build path used.
- Name new app tests by purpose (`vector-burst-test`, `sp-fmatmul-opt-burst-merge`) and keep each app in its own folder with `main.c`.
- When debugging stalls, keep wave dumps enabled and note the key signal path in the change description.

## Commit & Pull Request Guidelines
- Match recent history: imperative, scope-first subjects such as `mempool_group_mshr: harden burst response handling`.
- Keep commits focused; separate RTL, software, and config churn where practical.
- PRs should include: affected configs/apps, exact build/sim commands, observed result, and waveform or trace references for behavioral fixes.
- Call out changes under `hardware/deps/` explicitly, since they affect vendored code.
