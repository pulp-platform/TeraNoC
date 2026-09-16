#!/usr/bin/env python3
"""Build an isolated Qwen app, packed inputs, and a complete host reference."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import numpy as np
from elftools.elf.elffile import ELFFile

HERE = Path(__file__).resolve().parent
RTL = HERE.parents[3]


def sha(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for b in iter(lambda: f.read(1024 * 1024), b""):
            h.update(b)
    return h.hexdigest()


def padded(n, tile):
    return (n + tile - 1) // tile * tile


def projection(x, kdim, pdim, kt, pt, dtype, seed, path):
    """Write each weight once in target DMA order; emulate native inner sums.

    FP16 FMA uses exact-enough FP64 products/sums before rounding to FP16.
    FP32 uses FP64 intermediates for a numerical oracle (not bit-exact fmaf).
    Outer reduction tiles accumulate in FP32, as in the target wrapper.
    """
    rng = np.random.default_rng(seed)
    out = np.zeros((len(x), pdim), dtype=np.float32)
    with path.open("wb") as f:
        for p in range(0, pdim, pt):
            acc = np.zeros((len(x), pt), dtype=np.float32)
            for k in range(0, kdim, kt):
                w = rng.integers(-4, 5, size=(kt, pt)).astype(dtype)
                w *= dtype(1 / 64)
                w[min(kt, kdim - k) :, :] = 0
                w[:, min(pt, pdim - p) :] = 0
                f.write(w.tobytes())
                a = np.zeros((len(x), kt), dtype=dtype)
                a[:, : min(kt, kdim - k)] = x[:, k : k + kt]
                partial = (
                    a[:, 0, None].astype("float64") * w[None, 0, :].astype("float64")
                ).astype(dtype)
                for j in range(1, kt):
                    partial = (
                        partial.astype("float64")
                        + a[:, j, None].astype("float64") * w[None, j, :].astype("float64")
                    ).astype(dtype)
                acc += partial.astype("float32")
            out[:, p : p + pt] = acc[:, : min(pt, pdim - p)]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--mesh", type=int, choices=[4, 8], required=True)
    ap.add_argument(
        "--app", choices=["gemm_stream", "ffn_stream", "dma_probe"], default="ffn_stream"
    )
    ap.add_argument("--batch", type=int, default=4)
    ap.add_argument("--hidden", type=int, default=256)
    ap.add_argument("--intermediate", type=int, default=512)
    ap.add_argument("--kt", type=int, default=64)
    ap.add_argument("--pt", type=int, default=256)
    ap.add_argument("--ks", type=int, choices=[1, 2, 4, 8], default=1)
    ap.add_argument("--precision", type=int, choices=[16, 32], default=32)
    ap.add_argument("--overlap", type=int, choices=[0, 1], default=1)
    ap.add_argument("--active-groups", type=int)
    ap.add_argument("--seed", type=int, default=20260916)
    ap.add_argument("--l2-bytes", type=int)
    args = ap.parse_args()
    if args.l2_bytes is not None and (
        not 0x1000000 <= args.l2_bytes <= 0x20000000 or args.l2_bytes % 2048
    ):
        ap.error("L2 capacity must be 16–512 MiB, fit below ROM and divide both bank geometries")
    if min(args.batch, args.hidden, args.intermediate, args.kt, args.pt) <= 0:
        ap.error("Dimensions must be positive")
    if args.batch % args.ks or args.kt < 2 or args.kt % 2:
        ap.error("KS must divide batch; KT must be even and >= 2")
    if args.app == "dma_probe":
        if args.precision != 32 or args.batch * args.hidden % 256:
            ap.error("DMA probe requires FP32 and a multiple of 256 source words")
        available = padded(args.hidden, args.kt) * padded(args.intermediate, args.pt)
        if available < 8 * args.batch * args.hidden + 256:
            ap.error("DMA probe source is too small for eight shifted copies")
    nrow = args.batch // args.ks
    maxcores = nrow * args.pt // (64 // (args.precision // 8))
    groups = (
        min(args.mesh**2, maxcores // 16) if args.active_groups is None else args.active_groups
    )
    # Whole groups and exact column partitions. Deliberately avoid tiny loads.
    if groups < 1 or groups > args.mesh**2 or args.mesh**2 % groups:
        ap.error("Choose a wider PT or a legal active-group divisor")
    if groups * 16 % nrow or args.pt % (groups * 16 // nrow):
        ap.error("PT and batch do not admit this core partition")
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    src = args.out / "source"
    (src / "software/apps/spatz_apps").mkdir(parents=True)
    shutil.copytree(RTL / "config", src / "config")
    shutil.copytree(
        RTL / "software/runtime",
        src / "software/runtime",
        ignore=shutil.ignore_patterns("*.o", "*.pyc", "__pycache__", "arch.ld"),
    )
    apps = src / "software/apps/spatz_apps"
    shutil.copytree(HERE, apps / HERE.name, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    for name in ["sp-fmatmul-opt-burst-merge", "sp-fmatmul-opt-burst-merge-fp16"]:
        shutil.copytree(RTL / "software/apps/spatz_apps" / name / "kernel", apps / name / "kernel")
    # Strictly scoped adaptation: independent C row stride for tile-local scratch.
    # No changes to ASM, A/B addressing, burst logic, or the shared kernel files.
    kernel_name = "sp-fmatmul-opt-burst-merge" + ("-fp16" if args.precision == 16 else "")
    kernel = (apps / kernel_name / "kernel/sp-fmatmul.c").read_text()
    if kernel.count("c_ + m * P") != 4 or kernel.count("c__ += P") != 11:
        raise ValueError("Kernel output layout changed; review the adapter")
    kernel = kernel.replace("c_ + m * P", "c_ + m * Q_C_STRIDE").replace(
        "c__ += P", "c__ += Q_C_STRIDE"
    )
    (args.out / "qwen_microkernel.h").write_text(kernel)
    dtype = np.float16 if args.precision == 16 else np.float32
    x = np.random.default_rng(args.seed).integers(-4, 5, (args.batch, args.hidden)).astype(dtype)
    x *= dtype(1 / 16)
    packed_x = np.zeros((padded(args.hidden, args.kt) // args.kt, args.batch, args.kt), dtype=dtype)
    for k in range(0, args.hidden, args.kt):
        packed_x[k // args.kt, :, : min(args.kt, args.hidden - k)] = x[:, k : k + args.kt]
    packed_x.tofile(args.out / "x.bin")
    gate = projection(
        x,
        args.hidden,
        args.intermediate,
        args.kt,
        args.pt,
        dtype,
        args.seed + 1,
        args.out / "gate.bin",
    )
    if args.app == "ffn_stream":
        up = projection(
            x,
            args.hidden,
            args.intermediate,
            args.kt,
            args.pt,
            dtype,
            args.seed + 2,
            args.out / "up.bin",
        )
        h = ((gate.astype("float64") / (1 + np.exp(-gate.astype("float64")))) * up).astype(dtype)
        expected = projection(
            h,
            args.intermediate,
            args.hidden,
            args.kt,
            args.pt,
            dtype,
            args.seed + 3,
            args.out / "down.bin",
        )
        expected.tofile(args.out / "expected_output.bin")
    else:
        h = gate.astype(dtype)
        for name in ["up", "down"]:
            (args.out / (name + ".bin")).write_bytes(bytes(args.precision // 8))
    h.tofile(args.out / "expected_h.bin")
    definitions = dict(
        Q_BATCH=args.batch,
        Q_HIDDEN=args.hidden,
        Q_INTERMEDIATE=args.intermediate,
        Q_KT=args.kt,
        Q_PT=args.pt,
        Q_KS=args.ks,
        Q_PRECISION=args.precision,
        Q_OVERLAP=args.overlap,
        Q_ACTIVE_GROUPS=groups,
    )
    (args.out / "qwen_config.h").write_text(
        "#pragma once\n" + "".join(f"#define {k} {v}\n" for k, v in definitions.items())
    )
    assembly = '.section .l2,"aw",@progbits\n'
    for name, file in [
        ("q_x_data", "x"),
        ("q_gate_weights", "gate"),
        ("q_up_weights", "up"),
        ("q_down_weights", "down"),
    ]:
        assembly += f'.balign {64*256*(args.mesh**2//16)}\n.global {name}\n{name}:\n.incbin "{args.out}/{file}.bin"\n'
    (args.out / "data.S").write_text(assembly)
    appsrc = apps / HERE.name / args.app / "main.c"
    runtime = src / "software/runtime"
    makefile = f"""include {runtime}/runtime.mk
.DEFAULT_GOAL := workload.elf
RISCV_CCFLAGS += -I{args.out} -I{apps/kernel_name}/kernel -fno-vectorize -fno-slp-vectorize -mno-fdiv -fstack-usage -Wframe-larger-than=384 -Werror=frame-larger-than
workload.elf: app.o data.o $(RUNTIME) $(LINKER_SCRIPT)
\t$(RISCV_CC) -o $@ app.o data.o $(RUNTIME) $(RISCV_LDFLAGS) -T{runtime}/link.ld -Wl,-Map,workload.map
app.o: {appsrc}
\t$(RISCV_CC) $(RISCV_CCFLAGS) -c $< -o $@
data.o: data.S
\t$(RISCV_CC) $(RISCV_CCFLAGS) -c $< -o $@
config_report:
\t@echo $(DEFINES)
"""
    (args.out / "Makefile").write_text(makefile)
    cmd = [
        "make",
        "-f",
        "Makefile",
        f"MEMPOOL_DIR={src}",
        f"config=terapool_spatz4_fpu" + ("_8x8" if args.mesh == 8 else ""),
        f"LLVM_INSTALL_DIR={RTL}/install/llvm",
        f"GCC_INSTALL_DIR={RTL}/install/riscv-gcc",
        "group_mshr_merge_reqs=16",
        "workload.elf",
        "config_report",
    ]
    if args.l2_bytes:
        cmd.insert(-2, f"l2_size={args.l2_bytes}")
    with (args.out / "build.log").open("w") as log:
        result = subprocess.run(cmd, cwd=args.out, stdout=log, stderr=subprocess.STDOUT)
    manifest = {
        **vars(args),
        "out": str(args.out),
        "active_groups": groups,
        "active_cores": groups * 16,
        "l2_operand_alignment": 64 * 256 * (args.mesh**2 // 16),
        "command": cmd,
        "build_returncode": result.returncode,
        "rtl_commit": subprocess.check_output(
            ["git", "-C", str(RTL), "rev-parse", "HEAD"], text=True
        ).strip(),
        "accumulation": f"fp{args.precision} within K tiles; fp32 between tiles",
        "input_kind": "deterministic synthetic; not pretrained model weights",
        "files": {str(p.relative_to(args.out)): sha(p) for p in args.out.glob("*.bin")},
        "microkernel_adapter_sha256": sha(args.out / "qwen_microkernel.h"),
        "source_sha256": {str(p.relative_to(src)): sha(p) for p in src.rglob("*") if p.is_file()},
    }
    if not result.returncode:
        manifest["elf_sha256"] = sha(args.out / "workload.elf")
        frames = {}
        for p in args.out.rglob("*.su"):
            for line in p.read_text().splitlines():
                name, size, kind = line.split("\t")
                frames[name.rsplit(":", 1)[-1]] = dict(bytes=int(size), kind=kind)
        manifest["stack_frames"] = frames
        manifest[
            "stack_check"
        ] = "384-byte individual-frame compiler limit; call-chain budget must also fit the 512-byte stack"
        with (args.out / "workload.elf").open("rb") as f:
            elf = ELFFile(f)
            syms = {
                s.name: int(s["st_value"])
                for s in elf.get_section_by_name(".symtab").iter_symbols()
            }
            manifest["memory"] = dict(
                l1_static_and_stacks=syms["__l1_alloc_base"],
                l1_usable=syms["__l1_end"],
                l1_headroom=syms["__l1_end"] - syms["__l1_alloc_base"],
                stack_bytes_per_core=(syms["__stack_end"] - syms["__stack_start"])
                // (args.mesh**2 * 16),
                l2_payload_bytes=int(elf.get_section_by_name(".l2")["sh_size"]),
            )
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(
        json.dumps({k: manifest[k] for k in ["build_returncode", "active_groups", "accumulation"]})
    )
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
