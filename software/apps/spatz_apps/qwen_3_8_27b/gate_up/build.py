#!/usr/bin/env python3
"""Build isolated FP16-storage/FP32-accumulation Gate/Up projections."""
import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path
import numpy as np
from elftools.elf.elffile import ELFFile

HERE = Path(__file__).resolve().parent
RTL = HERE.parents[4]


def sha(p):
    with Path(p).open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def align(n, a):
    return (n + a - 1) // a * a


def layout(p, workers, kt, tail_width=8):
    if p % workers:
        raise ValueError("Output width must divide column workers")
    left = p // workers
    segments, woff, aoff, col = [], 0, 0, 0
    while left:
        valid = min(32, left)
        width = align(valid, tail_width)
        astride = align(width, 16)
        segments.append(
            dict(valid=valid, width=width, woff=woff, aoff=aoff, astride=astride, col=col)
        )
        woff += kt * workers * width
        aoff += workers * astride
        col += workers * valid
        left -= valid
    return segments, woff, aoff


def microkernel(a, segments, workers, partial_row):
    local_partial = a.partial_layout == "local"

    def partial_index(seg, row, index):
        base = f'({row})*{partial_row}+{seg["aoff"]}'
        if local_partial:
            # A 16-float register half occupies one tile's 64-byte bank stripe.
            # Interleave halves across workers instead of putting two adjacent
            # stripes at the same worker's address.
            return base + f"+(({index})/16)*{workers*16}+worker*16+({index})%16"
        return base + f'+worker*{seg["astride"]}+{index}'

    lines = ["// Generated register blocks: FP16 loads and widening FP32 FMACs."]
    if a.x_tile == "local":
        lines += [
            "__attribute__((noinline)) static void q_prefetch_x(const _Float16 *src, _Float16 *dst) {",
            '  asm volatile("vsetvli t0, %0, e16, m1, ta, ma\\n"',
            '               "vle16.v v0, (%1)\\nvse16.v v0, (%2)\\nfence\\n"',
            '               :: "r"(Q_KT), "r"(src), "r"(dst) : "t0", "v0", "memory");',
            "}",
        ]
    groups = [
        segments[i : i + max(1, 6 // a.rows)] for i in range(0, len(segments), max(1, 6 // a.rows))
    ]
    for bi, group in enumerate(groups):
        lines += [
            f"__attribute__((noinline)) static void q_block_{bi}(uint32_t worker, uint32_t row, uint32_t t, const _Float16 *w, const _Float16 *input) {{"
        ]
        code, outputs, inputs, clobbers = [], [], [], ["t0", "memory"]
        partial_vls = set()
        for r in range(a.rows):
            offset = f"{r}*NUM_CORES*Q_KT" if a.x_tile == "local" else f"(row+{r})*Q_HIDDEN+t*Q_KT"
            lines += [f"  const _Float16 *x{r}=input+{offset};"]
            outputs.append(f'[x{r}] "+&r"(x{r})')
            clobbers.append(f"ft{r}")
        lines += ["  uint32_t count=Q_KT;"]
        outputs += ['[n] "+&r"(count)']
        for s, seg in enumerate(group):
            width, pad = seg["width"], seg["astride"]
            lines += [f'  const _Float16 *w{s}=w+{seg["woff"]}+worker*{width};']
            outputs.append(f'[w{s}] "+&r"(w{s})')
            inputs += [f'[step{s}] "r"({workers*width*2})', f'[vl{s}] "r"({width})']
            if not local_partial:
                code.append(f"vsetvli t0, %[vl{s}], e32, m2, ta, ma")
            for r in range(a.rows):
                reg = 8 + 2 * (s * a.rows + r)
                if local_partial:
                    for h in range((width + 15) // 16):
                        n = min(16, width - h * 16)
                        if n not in partial_vls:
                            inputs.append(f'[pvl{n}] "r"({n})')
                            partial_vls.add(n)
                        operand = f"a{s}_{r}_{h}"
                        offset = partial_index(seg, f"row+{r}", str(h * 16))
                        lines.append(f"  float *{operand}=q_partial+{offset};")
                        inputs.append(f'[{operand}] "r"({operand})')
                        code += [
                            f"vsetvli t0, %[pvl{n}], e32, m1, ta, ma",
                            f"vle32.v v{reg+h}, (%[{operand}])",
                        ]
                else:
                    lines += [
                        f'  float *a{s}_{r}=q_partial+(row+{r})*{partial_row}+{seg["aoff"]}+worker*{pad};'
                    ]
                    inputs.append(f'[a{s}_{r}] "r"(a{s}_{r})')
                    code.append(f"vle32.v v{reg}, (%[a{s}_{r}])")
                clobbers += [f"v{reg}", f"v{reg+1}"]
        fixed_vl = a.vset_policy == "hoist" and len({s["width"] for s in group}) == 1
        if fixed_vl:
            code += ["vsetvli t0, %[vl0], e16, m1, ta, ma"]
        code += ["1:"]
        for r in range(a.rows):
            code += [f"flh ft{r}, 0(%[x{r}])", f"addi %[x{r}], %[x{r}], 2"]
        last_width = None
        for s, seg in enumerate(group):
            if not fixed_vl and (a.vset_policy != "hoist" or seg["width"] != last_width):
                code += [f"vsetvli t0, %[vl{s}], e16, m1, ta, ma"]
            # Distinct registers let the next segment load avoid reusing the
            # previous segment's still-live vector source. Accumulators start at v8.
            weight_reg = s if a.weight_registers == "separate" else 0
            code += [f"vle16.v v{weight_reg}, (%[w{s}])"]
            last_width = seg["width"]
            for r in range(a.rows):
                code += [f"vfwmacc.vf v{8+2*(s*a.rows+r)}, ft{r}, v{weight_reg}"]
            code += [f"add %[w{s}], %[w{s}], %[step{s}]"]
        code += ["addi %[n], %[n], -1", "bnez %[n], 1b"]
        for s, seg in enumerate(group):
            if local_partial:
                for r in range(a.rows):
                    for h in range((seg["width"] + 15) // 16):
                        n = min(16, seg["width"] - h * 16)
                        code += [
                            f"vsetvli t0, %[pvl{n}], e32, m1, ta, ma",
                            f"vse32.v v{8+2*(s*a.rows+r)+h}, (%[a{s}_{r}_{h}])",
                        ]
            else:
                code += [f"vsetvli t0, %[vl{s}], e32, m2, ta, ma"]
                for r in range(a.rows):
                    code += [f"vse32.v v{8+2*(s*a.rows+r)}, (%[a{s}_{r}])"]
        lines += ["  asm volatile("] + [f'    "{x}\\n"' for x in code]
        lines += [
            "    : " + ", ".join(outputs),
            "    : " + ", ".join(inputs),
            "    : "
            + ", ".join(
                f'"{x}"'
                for x in clobbers
                + [f"v{i}" for i in range(len(group) if a.weight_registers == "separate" else 1)]
            )
            + ");",
            "}",
        ]
    row_loop = (
        "for(uint32_t row=0;row<Q_BATCH;row+=Q_ROWS)"
        if a.distribution == "shared"
        else "for(uint32_t row=(cid/Q_WORKERS)*Q_ROWS;row<(cid/Q_WORKERS+1)*Q_ROWS;row+=Q_ROWS)"
    )
    lines += [
        "__attribute__((noinline)) static void q_compute(uint32_t cid,uint32_t t,const _Float16 *w) {",
        "  uint32_t worker=cid%Q_WORKERS;",
        "  const _Float16 *input=q_x+(Q_X_REPLICAS>1 ? cid/NUM_CORES_PER_GROUP : 0)*Q_X_REPLICA_ELEMENTS;",
        f"  {row_loop} {{",
    ]
    if a.x_tile == "local":
        lines += [
            "    for(uint32_t r=0;r<Q_ROWS;++r)",
            "      q_prefetch_x(input+(row+r)*Q_HIDDEN+t*Q_KT,q_x_tile[r][cid]);",
        ]
    block_input = "q_x_tile[0][cid]" if a.x_tile == "local" else "input"
    lines += [f"    q_block_{i}(worker,row,t,w,{block_input});" for i in range(len(groups))]
    lines += [
        "  }",
        "}",
        "__attribute__((noinline)) static void q_zero(uint32_t cid) {",
        "  uint32_t worker=cid%Q_WORKERS;",
        f"  {row_loop} {{",
    ]
    for seg in segments:
        index = partial_index(seg, "row+r", "j")
        lines += [
            f'    for(uint32_t r=0;r<Q_ROWS;++r) for(uint32_t j=0;j<{seg["astride"]};++j)',
            f"      q_partial[{index}]=0;",
        ]
    lines += [
        "  }",
        "}",
        "__attribute__((noinline)) static void q_store(uint32_t cid,float *out) {",
        "  uint32_t worker=cid%Q_WORKERS;",
        f"  {row_loop} {{",
    ]
    for seg in segments:
        index = partial_index(seg, "row+r", "j")
        lines += [
            f'    for(uint32_t r=0;r<Q_ROWS;++r) for(uint32_t j=0;j<{seg["valid"]};++j)',
            f'      out[(row+r)*Q_INTERMEDIATE+{seg["col"]}+worker*{seg["valid"]}+j]=q_partial[{index}];',
        ]
    return "\n".join(lines + ["  }", "}", ""])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--mesh", type=int, choices=[4, 8], default=4)
    ap.add_argument("--batch", type=int, default=1)
    ap.add_argument("--rows", type=int, choices=[1, 2, 4], default=1)
    ap.add_argument("--distribution", choices=["shared", "split"], default="shared")
    ap.add_argument("--hidden", type=int, default=5120)
    ap.add_argument("--intermediate", type=int, default=17408)
    ap.add_argument("--kt", type=int, default=32)
    ap.add_argument("--overlap", type=int, choices=[0, 1], default=1)
    ap.add_argument("--tail-width", type=int, choices=[8, 32], default=8)
    ap.add_argument("--barrier", choices=["flat", "group"], default="group")
    ap.add_argument("--x-replicas", choices=["one", "group"], default="group")
    ap.add_argument("--x-tile", choices=["off", "local"], default="off")
    ap.add_argument("--partial-layout", choices=["linear", "local"], default="linear")
    ap.add_argument("--vset-policy", choices=["each-segment", "hoist"], default="each-segment")
    ap.add_argument("--weight-registers", choices=["shared", "separate"], default="shared")
    ap.add_argument("--repeats", type=int, default=1)
    ap.add_argument("--pattern", choices=["random", "zero", "unit"], default="random")
    ap.add_argument("--unit-k", type=int, default=31)
    ap.add_argument("--seed", type=int, default=20260917)
    ap.add_argument("--app-source", type=Path, help="Build a focused runtime probe instead")
    a = ap.parse_args()
    if (
        min(a.batch, a.hidden, a.intermediate, a.kt, a.repeats) <= 0
        or a.batch % a.rows
        or a.hidden % a.kt
    ):
        ap.error("Positive dimensions, rows dividing batch and KT dividing K required")
    if a.x_tile == "local" and a.kt != 32:
        ap.error("Local X slices currently require KT32 to match the 64-byte tile stripe")
    if a.partial_layout == "local" and a.distribution != "shared":
        ap.error("Local partial sums currently require the all-core shared-column distribution")
    cores = a.mesh * a.mesh * 16
    teams = 1 if a.distribution == "shared" else a.batch // a.rows
    if cores % teams:
        ap.error("Row teams must divide the mesh")
    workers = cores // teams
    segments, welems, arow = layout(a.intermediate, workers, a.kt, a.tail_width)
    if (
        4 * a.hidden * workers * sum(s["width"] for s in segments)
        + a.batch * a.hidden * 2
        + 3 * 64 * cores
        > 536870912
    ):
        ap.error("Packed Gate+Up weights exceed the 512 MiB L2 aperture; choose a smaller layout")
    a.out = a.out.resolve()
    a.out.mkdir(parents=True, exist_ok=False)
    src = a.out / "source"
    (src / "software").mkdir(parents=True)
    shutil.copytree(RTL / "config", src / "config")
    shutil.copytree(
        RTL / "software/runtime",
        src / "software/runtime",
        ignore=shutil.ignore_patterns("*.o", "*.pyc", "__pycache__", "arch.ld"),
    )
    shutil.copytree(
        HERE,
        src / "software/apps/spatz_apps/qwen_3_8_27b/gate_up",
        ignore=shutil.ignore_patterns("__pycache__"),
    )
    rng = np.random.default_rng(a.seed)
    x = (rng.integers(-4, 5, (a.batch, a.hidden)) / 16).astype("<f2")
    if a.pattern == "zero":
        x[:] = 0
    if a.pattern == "unit":
        if not 0 <= a.unit_k < a.hidden:
            ap.error("unit-k outside input")
        x[:] = 0
        x[:, a.unit_k] = 1
    x.tofile(a.out / "x.bin")
    for stage in ["gate", "up"]:
        y = np.zeros((a.batch, a.intermediate), np.float32)
        with (a.out / f"{stage}.bin").open("wb") as f:
            for k in range(0, a.hidden, a.kt):
                # Generate logical row-major weights before packing; oracle does
                # not use the target's address expressions or packed representation.
                logical = (rng.integers(-4, 5, (a.kt, a.intermediate)) / 64).astype("<f2")
                for r in range(a.kt):
                    y = (
                        y.astype(np.float64)
                        + x[:, k + r, None].astype(np.float64) * logical[r].astype(np.float64)
                    ).astype(np.float32)
                for s in segments:
                    packed = np.zeros((a.kt, workers, s["width"]), dtype="<f2")
                    packed[:, :, : s["valid"]] = logical[
                        :, s["col"] : s["col"] + workers * s["valid"]
                    ].reshape(a.kt, workers, s["valid"])
                    f.write(packed.tobytes())
        y.tofile(a.out / f"expected_{stage}.bin")
    defines = dict(
        Q_BATCH=a.batch,
        Q_HIDDEN=a.hidden,
        Q_INTERMEDIATE=a.intermediate,
        Q_KT=a.kt,
        Q_ROWS=a.rows,
        Q_TEAMS=teams,
        Q_WORKERS=workers,
        Q_WEIGHT_ELEMENTS=welems,
        Q_PARTIAL_ELEMENTS=a.batch * arow,
        Q_GROUP_BARRIER=int(a.barrier == "group"),
        Q_LOCAL_X_TILE=int(a.x_tile == "local"),
        Q_X_REPLICAS=(a.mesh * a.mesh if a.x_replicas == "group" else 1),
        Q_X_REPLICA_ELEMENTS=(
            (align(a.batch * a.hidden * 2, 1024) // 1024 | 1) * 512
            if a.x_replicas == "group"
            else a.batch * a.hidden
        ),
        Q_OVERLAP=a.overlap,
        Q_REPEATS=a.repeats,
    )
    (a.out / "qwen_config.h").write_text(
        "#pragma once\n" + "".join(f"#define {k} {v}\n" for k, v in defines.items())
    )
    (a.out / "microkernel.h").write_text(microkernel(a, segments, workers, arow))
    asm = '.section .l2,"aw",@progbits\n'
    for sym, name in [("q_x_data", "x"), ("q_gate_weights", "gate"), ("q_up_weights", "up")]:
        asm += f'.balign {64*cores}\n.global {sym}\n{sym}:\n.incbin "{a.out}/{name}.bin"\n'
    (a.out / "data.S").write_text(asm)
    runtime = src / "software/runtime"
    app = src / "software/apps/spatz_apps/qwen_3_8_27b/gate_up/main.c"
    if a.app_source:
        shutil.copyfile(a.app_source, app)
    (a.out / "Makefile").write_text(
        f"""include {runtime}/runtime.mk
.DEFAULT_GOAL := workload.elf
RISCV_CCFLAGS += -I{a.out} -fno-vectorize -fno-slp-vectorize -fno-unroll-loops -mno-fdiv -fstack-usage -Wframe-larger-than=384 -Werror=frame-larger-than
workload.elf: app.o data.o $(RUNTIME) $(LINKER_SCRIPT)
\t$(RISCV_CC) -o $@ app.o data.o $(RUNTIME) $(RISCV_LDFLAGS) -T{runtime}/link.ld -Wl,-Map,workload.map
app.o: {app}
\t$(RISCV_CC) $(RISCV_CCFLAGS) -c $< -o $@
data.o: data.S
\t$(RISCV_CC) $(RISCV_CCFLAGS) -c $< -o $@
"""
    )
    cmd = [
        "make",
        "-f",
        "Makefile",
        f"MEMPOOL_DIR={src}",
        f"config=terapool_spatz4_fpu" + ("_8x8" if a.mesh == 8 else ""),
        f"LLVM_INSTALL_DIR={RTL}/install/llvm",
        f"GCC_INSTALL_DIR={RTL}/install/riscv-gcc",
        "group_mshr_merge_reqs=16",
        "l2_size=536870912",
        "workload.elf",
    ]
    with (a.out / "build.log").open("w") as f:
        rc = subprocess.run(cmd, cwd=a.out, stdout=f, stderr=subprocess.STDOUT).returncode
    m = {
        **vars(a),
        "out": str(a.out),
        "app_source": str(a.app_source) if a.app_source else None,
        "app": "gate_up",
        "precision": 16,
        "accumulation": "fp32 widening FMA for every multiply",
        "input_kind": "deterministic synthetic, not pretrained weights",
        "active_cores": cores,
        "active_groups": a.mesh * a.mesh,
        "l2_bytes": 536870912,
        "control_base": 0x20000000,
        "burst_model": "tile-contained-v1",
        "workers": workers,
        "teams": teams,
        "segments": segments,
        "weight_tile_bytes": welems * 2,
        "partial_row_elements": arow,
        "command": cmd,
        "build_returncode": rc,
        "rtl_commit": subprocess.check_output(
            ["git", "-C", str(RTL), "rev-parse", "HEAD"], text=True
        ).strip(),
        "generated_sha256": {
            n: sha(a.out / n) for n in ["microkernel.h", "qwen_config.h", "data.S"]
        },
        "source_sha256": {str(p.relative_to(src)): sha(p) for p in src.rglob("*") if p.is_file()},
        "files": {p.name: sha(p) for p in a.out.glob("*.bin")},
    }
    if not rc:
        m["elf_sha256"] = sha(a.out / "workload.elf")
        with (a.out / "workload.elf").open("rb") as f:
            elf = ELFFile(f)
            syms = {
                s.name: int(s["st_value"])
                for s in elf.get_section_by_name(".symtab").iter_symbols()
            }
            m["memory"] = {
                "l1_static_and_stacks": syms["__l1_alloc_base"],
                "l1_usable": syms["__l1_end"],
                "l1_headroom": syms["__l1_end"] - syms["__l1_alloc_base"],
            }
        m["stack_frames"] = [
            line for p in a.out.rglob("*.su") for line in p.read_text().splitlines()
        ]
    (a.out / "manifest.json").write_text(json.dumps(m, indent=2) + "\n")
    print(json.dumps({"returncode": rc, "out": str(a.out), "weight_tile_bytes": welems * 2}))
    raise SystemExit(rc)


if __name__ == "__main__":
    main()
