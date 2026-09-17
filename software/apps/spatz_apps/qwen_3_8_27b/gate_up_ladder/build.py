#!/usr/bin/env python3
"""Build a matched native-FP16 panel pipeline with production GEMM ownership."""
import argparse
from collections import Counter
import json
import math
from pathlib import Path
import shutil
import subprocess
import numpy as np
from elftools.elf.elffile import ELFFile
from data import sha
from partition import select, assignments

HERE = Path(__file__).resolve().parent
RTL = HERE.parents[4]


def align(n, multiple):
    return (n + multiple - 1) // multiple * multiple


def symbols(elf):
    with elf.open("rb") as stream:
        return {
            s.name: int(s["st_value"])
            for s in ELFFile(stream).get_section_by_name(".symtab").iter_symbols()
        }


def kernel(rows):
    text = [
        "// Generated native FP16 block, preserving sums across K tiles.",
        "static inline void q_owner(uint32_t cid, uint32_t *first, uint32_t *last, uint32_t *pb) {",
        "#if !Q_MATMUL",
        "*first=0; *last=Q_BATCH; *pb=cid;",
        "#elif Q_DECODE",
        "*first=(cid%(Q_BATCH/Q_ROWS))*Q_ROWS;",
        "*last=*first+Q_ROWS; *pb=cid/(Q_BATCH/Q_ROWS);",
        "#elif Q_GROUP_ROWS/Q_ROWS < NUM_CORES_PER_GROUP",
        "*first=(cid/NUM_CORES_PER_GROUP)*Q_GROUP_ROWS+(cid%NUM_CORES_PER_GROUP)/Q_PBLOCKS*Q_ROWS;",
        "*last=*first+Q_ROWS; *pb=(cid%NUM_CORES_PER_GROUP)%Q_PBLOCKS;",
        "#else",
        "*first=(cid/NUM_CORES_PER_GROUP)*Q_GROUP_ROWS+(cid%NUM_CORES_PER_GROUP)*(Q_GROUP_ROWS/NUM_CORES_PER_GROUP);",
        "*last=*first+Q_GROUP_ROWS/NUM_CORES_PER_GROUP; *pb=0;",
        "#endif",
        "}",
        "__attribute__((noinline)) static void q_block(uint32_t row,uint32_t col,const _Float16 *w,const _Float16 *x) {",
    ]
    ops = ["vsetvli t0, %[vl], e16, m1, ta, ma"]
    outputs, inputs, clobbers = [], [], ["t0", "v0", "memory"]
    for r in range(rows):
        text += [
            f"const _Float16 *x{r}=x+(row+{r})*Q_KT;",
            f"_Float16 *a{r}=q_partial+(row+{r})*Q_PT+col;",
        ]
        outputs += [f'[x{r}] "+&r"(x{r})']
        inputs += [f'[a{r}] "r"(a{r})']
        clobbers += [f"ft{r}", f"v{8+r}"]
        ops += [f"vle16.v v{8+r}, (%[a{r}])"]
    text += ["const _Float16 *weights=w+col;", "uint32_t n=Q_KT;"]
    outputs += ['[w] "+&r"(weights)', '[n] "+&r"(n)']
    inputs += ['[stride] "r"(2*Q_PT)', '[vl] "r"(Q_VL)']
    ops += ["1:"]
    for r in range(rows):
        ops += [f"flh ft{r}, 0(%[x{r}])", f"addi %[x{r}], %[x{r}], 2"]
    ops += ["vle16.v v0, (%[w])"]
    for r in range(rows):
        ops += [f"vfmacc.vf v{8+r}, ft{r}, v0"]
    ops += ["add %[w], %[w], %[stride]", "addi %[n], %[n], -1", "bnez %[n], 1b"]
    for r in range(rows):
        ops += [f"vse16.v v{8+r}, (%[a{r}])"]
    text += ["asm volatile("] + [f'"{op}\\n"' for op in ops]
    text += [
        ": " + ",".join(outputs),
        ": " + ",".join(inputs),
        ": " + ",".join('"' + x + '"' for x in clobbers) + ");",
        "}",
        "static void q_compute(uint32_t cid,uint32_t slot) {",
        "uint32_t first,last,pb; q_owner(cid,&first,&last,&pb);",
        "const _Float16 *x=q_x[slot]+(cid/NUM_CORES_PER_GROUP)*Q_X_STRIDE;",
        "for(uint32_t row=first;row<last;row+=Q_ROWS)",
        "for(uint32_t j=0;j<Q_PANEL_SPAN;j+=Q_VL)",
        "q_block(row,pb*Q_PANEL_SPAN+j,q_weights[slot],x);",
        "}",
        "static void q_zero(uint32_t cid) {",
        "uint32_t first,last,pb; q_owner(cid,&first,&last,&pb);",
        "for(uint32_t row=first;row<last;++row)",
        "for(uint32_t j=0;j<Q_PANEL_SPAN;j+=Q_VL) {",
        "_Float16 *p=q_partial+row*Q_PT+pb*Q_PANEL_SPAN+j;",
        'asm volatile("vsetvli t0,%0,e16,m1,ta,ma\\nvmv.v.i v0,0\\nvse16.v v0,(%1)\\n"',
        ':: "r"(Q_VL),"r"(p):"t0","v0","memory");',
        "}",
        "}",
    ]
    return "\n".join(text) + "\n"


def hash_choices(m, syms):
    """Production spread/peak ranking on actual tiled remote operand addresses."""
    ng, kt, pt = m["active_groups"], m["kt"], m["pt"]
    span, vl, stride = m["panel_span"], m["vl"], m["x_stride_elements"]
    result = []
    for g in range(ng):
        samples = [[], []]
        owners = m["assignments"][g * 16 : (g + 1) * 16]
        for slot in range(2):
            for n in sorted(set(int(v) for v in np.linspace(0, kt - 1, min(16, kt)))):
                for j in sorted(
                    set(int(v) * vl for v in np.linspace(0, span // vl - 1, min(4, span // vl)))
                ):
                    singles, bursts = set(), set()
                    for owner in owners:
                        for row in sorted(
                            {
                                owner["row_start"],
                                max(owner["row_start"], owner["row_end"] - m["rows"]),
                            }
                        ):
                            for r in range(m["rows"]):
                                addr = syms["q_x"] + 2 * (
                                    slot * ng * stride + g * stride + (row + r) * kt + n
                                )
                                if (addr // 1024) % ng != g:
                                    singles.add(addr // 4)
                        addr = syms["q_weights"] + 2 * (
                            slot * kt * pt + n * pt + owner["pblock"] * span + j
                        )
                        assert addr % 4 == 0 and (addr % 64 + vl * 2 <= 64 or addr % 16 == 0)
                        if (addr // 1024) % ng != g:
                            bursts.add(addr // 4)
                    samples[0].append(singles)
                    samples[1].append(bursts)
        selected = []
        for cls in range(2):
            candidates = []
            for shift in range(4, 11):
                for bits in range(2 if cls else 1):
                    if shift < 4 + bits:
                        continue
                    histogram, spread = Counter(), 0
                    for sample in samples[cls]:
                        banks = [
                            (((word >> shift) << bits) | ((word >> 4) & bits)) & 15
                            for word in sample
                        ]
                        histogram.update(banks)
                        spread += len(set(banks))
                    peak = max(histogram.values(), default=0)
                    candidates.append((-spread, peak, shift, bits))
            best = min(candidates)
            selected.append(dict(shift=best[2], bits=best[3], spread=-best[0], peak=best[1]))
        result.append(selected)
    return result


def csr_header(out, configs):
    fields = [
        "hold_subs_single",
        "hold_subs_burst",
        "hold_window_single",
        "hold_window_burst",
        "serve_timeout",
        "bank_shift_single",
        "bank_shift_burst",
        "bank_burst_bits",
        "cache_reuse_target",
        "cache_timeout",
        "bankfull_backpressure",
    ]
    out.write_text(
        "static const mshr_cfg_t q_csr[NUM_GROUPS] = {\n"
        + ",\n".join(
            "{" + ",".join("." + k + "=" + str(v[k]) for k in fields) + "}" for v in configs
        )
        + "\n};\n"
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--dataset", type=Path, required=True)
    ap.add_argument("--platform-source", type=Path, required=True)
    ap.add_argument("--mesh", type=int, choices=[4, 8], required=True)
    ap.add_argument("--batch", type=int, required=True)
    ap.add_argument("--mapping", choices=["auto", "register", "matmul"], default="auto")
    ap.add_argument("--mshr", choices=["bypass", "merge"], default="merge")
    ap.add_argument("--kt", type=int, default=32)
    ap.add_argument("--pt", type=int, default=0)
    ap.add_argument("--repeats", type=int, default=1)
    a = ap.parse_args()
    a.out = a.out.resolve()
    a.dataset = a.dataset.resolve()
    a.out.mkdir(parents=True, exist_ok=False)
    d = json.loads((a.dataset / "dataset.json").read_text())
    B, K, P, ng = a.batch, d["hidden"], d["intermediate"], a.mesh * a.mesh
    if a.mapping == "auto":
        a.mapping = "register" if B == 1 else "matmul"
    assert 1 <= B <= d["batch"] and B & (B - 1) == 0 and K % a.kt == 0
    policy = select(a.platform_source / "software/runtime", a.out, a.mesh, B, K, P)
    partition = assignments(a.mesh, B, P, policy, a.mapping)
    stride = ((align(B * a.kt * 2, 1024) // 1024) | 1) * 512
    pt = a.pt or 8192

    def budget(pt):
        panels = math.ceil(P / pt)
        return (
            4 * K * pt * panels + 2 * (K // a.kt) * ng * stride + 4 * panels * B * pt + 1024 * 1024
        )

    while not a.pt and budget(pt) > 536870912:
        pt //= 2
    assert budget(pt) <= 536870912 and pt % partition["pblocks"] == 0
    span = pt // partition["pblocks"]
    vl = min(32, span)
    assert vl >= 4 and vl & (vl - 1) == 0
    panels = math.ceil(partition["pspan"] / span)
    src = a.out / "source"
    (src / "software").mkdir(parents=True)
    shutil.copytree(a.platform_source / "config", src / "config")
    shutil.copytree(
        a.platform_source / "software/runtime",
        src / "software/runtime",
        ignore=shutil.ignore_patterns("*.o", "*.pyc", "__pycache__", "arch.ld"),
    )
    shutil.copytree(
        HERE,
        src / "software/apps/spatz_apps/qwen_3_8_27b/gate_up_ladder",
        ignore=shutil.ignore_patterns("__pycache__"),
    )
    x = np.memmap(a.dataset / "x.bin", dtype="<f2", mode="r", shape=(d["batch"], K))[:B]
    x.tofile(a.out / "logical_x.bin")
    with (a.out / "x.bin").open("wb") as stream:
        for k in range(0, K, a.kt):
            tile = np.zeros((ng, stride), "<f2")
            tile[:, : B * a.kt] = x[:, k : k + a.kt].reshape(-1)
            stream.write(tile.tobytes())
    for stage in ["gate", "up"]:
        weights = np.memmap(a.dataset / f"{stage}.bin", dtype="<f2", mode="r", shape=(K, P))
        with (a.out / f"{stage}.bin").open("wb") as stream:
            for panel in range(panels):
                valid = min(span, partition["pspan"] - panel * span)
                for k in range(0, K, a.kt):
                    tile = np.zeros((a.kt, partition["pblocks"], span), "<f2")
                    for block in range(partition["pblocks"]):
                        start = block * partition["pspan"] + panel * span
                        tile[:, block, :valid] = weights[k : k + a.kt, start : start + valid]
                    stream.write(tile.tobytes())
        for prefix in ["expected_", "expected_fp16_"]:
            ref = np.memmap(
                a.dataset / f"{prefix}{stage}.bin", dtype="<f4", mode="r", shape=(d["batch"], P)
            )
            ref[:B].tofile(a.out / f"{prefix}{stage}.bin")
    defs = dict(
        Q_BATCH=B,
        Q_HIDDEN=K,
        Q_INTERMEDIATE=P,
        Q_KT=a.kt,
        Q_PT=pt,
        Q_STEPS=K // a.kt,
        Q_PANELS=panels,
        Q_ROWS=partition["ks"],
        Q_PBLOCKS=partition["pblocks"],
        Q_PANEL_SPAN=span,
        Q_VL=vl,
        Q_X_STRIDE=stride,
        Q_REPEATS=a.repeats,
        Q_MATMUL=int(a.mapping == "matmul"),
        Q_DECODE=policy["decode"],
        Q_GROUP_ROWS=B // ng,
        Q_REUSE_GUARD=128,
    )
    (a.out / "qwen_config.h").write_text(
        "#pragma once\n" + "".join(f"#define {k} {v}\n" for k, v in defs.items())
    )
    (a.out / "microkernel.h").write_text(kernel(partition["ks"]))
    asm = '.section .l2,"aw",@progbits\n'
    for sym, name in [("q_x_data", "x"), ("q_gate_weights", "gate"), ("q_up_weights", "up")]:
        asm += f'.balign 65536\n.global {sym}\n{sym}:\n.incbin "{a.out}/{name}.bin"\n'
    output_bytes = 4 * panels * B * pt
    asm += f".balign 65536\n.global q_output_l2\n.type q_output_l2,@object\nq_output_l2:\n.space {output_bytes}\n.size q_output_l2,{output_bytes}\n"
    (a.out / "data.S").write_text(asm)
    runtime = src / "software/runtime"
    app = src / "software/apps/spatz_apps/qwen_3_8_27b/gate_up_ladder/main.c"
    (a.out / "Makefile").write_text(
        f"""include {runtime}/runtime.mk
.DEFAULT_GOAL := workload.elf
RISCV_CCFLAGS += -I{a.out} -fno-vectorize -fno-slp-vectorize -fno-unroll-loops -mno-fdiv -fstack-usage -Wframe-larger-than=384 -Werror=frame-larger-than
workload.elf: app.o data.o $(RUNTIME) $(LINKER_SCRIPT)
\t$(RISCV_CC) -o $@ app.o data.o $(RUNTIME) $(RISCV_LDFLAGS) -T{runtime}/link.ld -Wl,-Map,workload.map
app.o: {app} csr_config.h microkernel.h qwen_config.h
\t$(RISCV_CC) $(RISCV_CCFLAGS) -c $< -o $@
data.o: data.S
\t$(RISCV_CC) $(RISCV_CCFLAGS) -c $< -o $@
"""
    )
    command = [
        "make",
        "-f",
        "Makefile",
        f"MEMPOOL_DIR={src}",
        "config=terapool_spatz4_fpu" + ("_8x8" if a.mesh == 8 else ""),
        f"LLVM_INSTALL_DIR={RTL}/install/llvm",
        f"GCC_INSTALL_DIR={RTL}/install/riscv-gcc",
        "group_mshr_merge_reqs=16",
        "l2_size=536870912",
        "workload.elf",
    ]
    cfg = dict(
        hold_subs_single=1,
        hold_subs_burst=1,
        hold_window_single=64,
        hold_window_burst=64,
        serve_timeout=64,
        bank_shift_single=4,
        bank_shift_burst=4,
        bank_burst_bits=0,
        cache_reuse_target=0,
        cache_timeout=0,
        bankfull_backpressure=1,
    )
    csr_header(a.out / "csr_config.h", [cfg] * ng)
    with (a.out / "build_initial.log").open("w") as log:
        subprocess.run(command, cwd=a.out, stdout=log, stderr=subprocess.STDOUT, check=True)
    initial = symbols(a.out / "workload.elf")
    m = dict(
        app="gate_up",
        experiment="partition_ladder",
        mesh=a.mesh,
        batch=B,
        hidden=K,
        intermediate=P,
        rows=partition["ks"],
        distribution=a.mapping,
        accumulator="fp16",
        precision=16,
        accumulation="native FP16 across the entire reduction; FP16 packed outputs in L2",
        fmac_per_core_cycle=8,
        active_groups=ng,
        active_cores=ng * 16,
        kt=a.kt,
        pt=pt,
        panels=panels,
        panel_span=span,
        vl=vl,
        pblocks=partition["pblocks"],
        pspan=partition["pspan"],
        assignments=partition["assignments"],
        matmul_policy=policy,
        workers=partition["pblocks"],
        segments=[dict(width=span)],
        repeats=a.repeats,
        overlap=1,
        barrier="group",
        output_storage="l2_packed_fp16",
        l2_bytes=536870912,
        control_base=0x20000000,
        weight_tile_bytes=2 * a.kt * pt,
        x_stride_elements=stride,
        x_tile_bytes=2 * ng * stride,
        x_replicas="group",
        x_tile="double_buffered",
        partial_layout="panel_row_major",
        vset_policy="hoist",
        weight_registers="shared",
        mshr_policy=a.mshr if a.mapping == "matmul" else "bypass",
        phase_csr_markers=True,
        dataset=str(a.dataset),
        dataset_manifest=d,
        values=d["values"],
        pattern=d["pattern"],
        expected_group_barrier_releases=4 + 2 * a.repeats * panels * (3 + 2 * (K // a.kt)),
        expected_fmac_per_group=[2 * a.repeats * B * K * pt * panels // ng] * ng,
        useful_flops=4 * a.repeats * B * K * P,
        reuse_guard_cycles=128,
        programmed_dma_bytes=dict(
            weights=4 * a.repeats * K * pt * panels,
            inputs=4 * a.repeats * panels * (K // a.kt) * ng * stride,
            outputs=a.repeats * output_bytes,
        ),
    )
    choices = hash_choices(m, initial)
    configs = []
    for g in range(ng):
        c = cfg.copy()
        c.update(
            bank_shift_single=choices[g][0]["shift"],
            bank_shift_burst=choices[g][1]["shift"],
            bank_burst_bits=choices[g][1]["bits"],
        )
        if a.mapping == "matmul" and a.mshr == "merge":
            c.update(
                hold_subs_single=policy["share_a"] if policy["share_a"] > 2 else 1,
                hold_subs_burst=policy["share_b"],
            )
            c["cache_reuse_target"] = 2 * c["hold_subs_single"] if c["hold_subs_single"] > 1 else 0
        configs.append(c)
    csr_header(a.out / "csr_config.h", configs)
    with (a.out / "build.log").open("w") as log:
        subprocess.run(command, cwd=a.out, stdout=log, stderr=subprocess.STDOUT, check=True)
    final = symbols(a.out / "workload.elf")
    assert all(initial[k] == final[k] for k in ["q_x", "q_weights", "q_partial", "q_output_l2"])
    names = [
        "enable",
        "hold_subs_single",
        "hold_subs_burst",
        "hold_window_single",
        "hold_window_burst",
        "bank_shift_single",
        "bank_shift_burst",
        "bank_burst_bits",
        "serve_timeout",
        "cache_reuse_target",
        "cache_timeout",
        "bankfull_backpressure",
    ]
    m.update(
        out=str(a.out),
        command=command,
        build_returncode=0,
        elf_sha256=sha(a.out / "workload.elf"),
        platform_source=str(a.platform_source),
        source_sha256={str(p.relative_to(src)): sha(p) for p in src.rglob("*") if p.is_file()},
        files={p.name: sha(p) for p in a.out.glob("*.bin")},
        generated_sha256={
            name: sha(a.out / name)
            for name in ["microkernel.h", "qwen_config.h", "csr_config.h", "data.S"]
        },
        memory=dict(
            l1_static_and_stacks=final["__l1_alloc_base"],
            l1_usable=final["__l1_end"],
            l1_headroom=final["__l1_end"] - final["__l1_alloc_base"],
            l2_budget_upper_bound=budget(pt),
        ),
        expected_csr={
            str(g): {str(i): 1 if i == 0 else c[name] for i, name in enumerate(names)}
            for g, c in enumerate(configs)
        },
        hash_analysis=dict(
            method="spread then peak, shift, bits; actual remote addresses, both buffers; static estimate",
            groups=choices,
        ),
        l1_symbols={k: final[k] for k in ["q_x", "q_weights", "q_partial"]},
        stack_frames=[line for p in a.out.rglob("*.su") for line in p.read_text().splitlines()],
    )
    (a.out / "manifest.json").write_text(json.dumps(m, indent=2) + "\n")
    print(
        json.dumps(
            {k: m[k] for k in ["out", "memory", "rows", "pt", "panels", "pblocks", "elf_sha256"]}
        )
    )


if __name__ == "__main__":
    main()
