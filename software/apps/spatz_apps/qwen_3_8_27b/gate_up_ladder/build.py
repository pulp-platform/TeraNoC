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
from tiling import select as select_tiling, vectors

HERE = Path(__file__).resolve().parent
RTL = HERE.parents[4]

# Tuned standalone FP16 GEMM MSHR policy. Keep these values aligned with
# config/terapool_spatz4_fpu.mk and sp-fmatmul-opt-burst-merge-fp16; they are
# latency/liveness policy and must not be replaced with shape-derived values.
MSHR_HOLD_WINDOW_SINGLE = 8191
MSHR_HOLD_WINDOW_BURST = 8191
MSHR_SERVE_TIMEOUT = 8191
MSHR_CACHE_TIMEOUT = 0


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
        "__attribute__((noinline)) static void q_block(uint32_t row,uint32_t col,const _Float16 *w,const _Float16 *x,uint32_t vl,uint32_t n) {",
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
    text += ["const _Float16 *weights=w+col;"]
    outputs += ['[w] "+&r"(weights)', '[n] "+&r"(n)']
    inputs += ['[stride] "r"(2*Q_PT)', '[vl] "r"(vl)']
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
        "static inline uint32_t q_vl(uint32_t col,uint32_t left) {",
        "uint32_t vl=32-(col%32); if(vl>left) vl=left;",
        "if(col%2) return 1; return vl>1 ? vl-(vl%2) : vl;",
        "}",
        "static void q_compute(uint32_t cid,uint32_t slot,uint32_t panel,uint32_t step) {",
        "uint32_t first,last,pb; q_owner(cid,&first,&last,&pb);",
        "uint32_t count=Q_PSPAN-panel*Q_PANEL_SPAN;",
        "if(count>Q_PANEL_SPAN) count=Q_PANEL_SPAN;",
        "uint32_t n=Q_HIDDEN-step*Q_KT; if(n>Q_KT) n=Q_KT;",
        "const _Float16 *x=q_x[slot]+(cid/NUM_CORES_PER_GROUP)*Q_X_STRIDE;",
        "for(uint32_t row=first;row<last;row+=Q_ROWS)",
        "for(uint32_t j=0;j<count;) {",
        "uint32_t col=pb*Q_PANEL_SPAN+j,vl=q_vl(col,count-j);",
        "q_block(row,col,q_weights[slot],x,vl,n); j+=vl; }",
        "}",
        "static void q_zero(uint32_t cid) {",
        "uint32_t first,last,pb; q_owner(cid,&first,&last,&pb);",
        "for(uint32_t row=first;row<last;++row)",
        "for(uint32_t j=0;j<Q_PANEL_SPAN;) {",
        "uint32_t vl=q_vl(pb*Q_PANEL_SPAN+j,Q_PANEL_SPAN-j);",
        "_Float16 *p=q_partial+row*Q_PT+pb*Q_PANEL_SPAN+j;",
        'asm volatile("vsetvli t0,%0,e16,m1,ta,ma\\nvmv.v.i v0,0\\nvse16.v v0,(%1)\\n"',
        ':: "r"(vl),"r"(p):"t0","v0","memory"); j+=vl;',
        "}",
        "}",
    ]
    return "\n".join(text) + "\n"


def request_samples(m, syms):
    """Sample the actual vector segments, including scalar halfword tails."""
    ng, kt, pt = m["active_groups"], m["kt"], m["pt"]
    span, stride = m["panel_span"], m["x_stride_elements"]
    groups = []
    points = lambda n, limit: sorted(set(int(v) for v in np.linspace(0, n - 1, min(limit, n))))
    for g in range(ng):
        owners = m["assignments"][g * 16 : (g + 1) * 16]
        cohorts, local = [], Counter()
        for panel in sorted({0, m["panels"] - 1}):
            count = min(span, m["pspan"] - panel * span)
            blocks = [list(vectors(o["pblock"] * span, count)) for o in owners]
            for slot in range(2):
                for n in points(min(kt, m["hidden"]), 16):
                    for j in points(max(map(len, blocks)), 4):
                        single, single_b, burst = set(), set(), set()
                        for owner, segments in zip(owners, blocks):
                            if j >= len(segments):
                                continue
                            for row in sorted({owner["row_start"], owner["row_end"] - m["rows"]}):
                                for r in range(m["rows"]):
                                    addr = syms["q_x"] + 2 * (
                                        slot * ng * stride + g * stride + (row + r) * kt + n)
                                    local["a_total"] += 1
                                    local["a_local"] += (addr // 1024) % ng == g
                                    if (addr // 1024) % ng != g:
                                        single.add(addr // 4)
                            col, vl = segments[j]
                            addr = syms["q_weights"] + 2 * (slot * kt * pt + n * pt + col)
                            assert vl <= 2 or (addr % 4 == 0 and addr % 64 + 2 * vl <= 64)
                            local["b_total"] += 1
                            local["b_local"] += (addr // 1024) % ng == g
                            if (addr // 1024) % ng != g:
                                (burst if vl >= 4 else single_b).add(addr // 4)
                        cohorts.append(dict(panel=panel, slot=slot, step=n, vector_index=j,
                                            single=sorted(single | single_b), single_b=sorted(single_b),
                                            burst=sorted(burst)))
        groups.append(dict(g=g, cohorts=cohorts, locality={
            cls: local[cls + "_local"] / local[cls + "_total"] for cls in ["a", "b"]}))
    return groups


def hash_choices(samples):
    """Production spread/peak ranking on actual tiled remote operand addresses."""
    result = []
    for group in samples:
        selected = []
        for cls in range(2):
            cohorts = [set(c["burst"] if cls else c["single"] + c["single_b"])
                       for c in group["cohorts"]]
            candidates = []
            for shift in range(4, 11):
                for bits in range(2 if cls else 1):
                    if shift < 4 + bits:
                        continue
                    histogram, spread = Counter(), 0
                    for sample in cohorts:
                        banks = [(((word >> shift) << bits) | ((word >> 4) & bits)) & 15
                                 for word in sample]
                        histogram.update(banks)
                        spread += len(set(banks))
                    candidates.append((-spread, max(histogram.values(), default=0), shift, bits))
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
    ap.add_argument("--kt", type=int, default=0)
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
    assert 1 <= B <= d["batch"] and B & (B - 1) == 0
    policy = select(a.platform_source / "software/runtime", a.out, a.mesh, B, K, P)
    partition = assignments(a.mesh, B, P, policy, a.mapping)
    tiling = select_tiling(a.mesh, B, K, P, partition["pblocks"], a.kt, a.pt)
    a.kt, pt, span = tiling["kt"], tiling["pt"], tiling["panel_span"]
    stride, steps, panels = tiling["x_stride_elements"], tiling["steps"], tiling["panels"]
    vl = 32
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
            count = min(a.kt, K - k)
            tile[:, : B * a.kt].reshape(ng, B, a.kt)[:, :, :count] = x[:, k : k + count]
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
                        count = min(a.kt, K - k)
                        tile[:count, block, :valid] = weights[k : k + count, start : start + valid]
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
        Q_STEPS=steps,
        Q_PSPAN=partition["pspan"],
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
        f"group_mshr_hold_window_single={MSHR_HOLD_WINDOW_SINGLE}",
        f"group_mshr_hold_window_burst={MSHR_HOLD_WINDOW_BURST}",
        f"group_mshr_serve_timeout={MSHR_SERVE_TIMEOUT}",
        f"group_mshr_cache_timeout={MSHR_CACHE_TIMEOUT}",
        "l2_size=536870912",
        "workload.elf",
    ]
    cfg = dict(
        hold_subs_single=1,
        hold_subs_burst=1,
        hold_window_single=MSHR_HOLD_WINDOW_SINGLE,
        hold_window_burst=MSHR_HOLD_WINDOW_BURST,
        serve_timeout=MSHR_SERVE_TIMEOUT,
        bank_shift_single=4,
        bank_shift_burst=4,
        bank_burst_bits=0,
        cache_reuse_target=0,
        cache_timeout=MSHR_CACHE_TIMEOUT,
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
        steps=steps,
        tiling_policy="mesh_full_width_v1",
        vector_policy="tile_contained_exact_tail_v1",
        compute_padding=False,
        tiling_budget=tiling,
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
        expected_group_barrier_releases=4 + 2 * a.repeats * panels * (3 + 2 * steps),
        expected_fmac_per_group=[sum(2 * a.repeats * K * (o["row_end"] - o["row_start"]) *
                                     (o["col_end"] - o["col_start"])
                                     for o in partition["assignments"] if o["group"] == g)
                                 for g in range(ng)],
        useful_flops=4 * a.repeats * B * K * P,
        reuse_guard_cycles=128,
        programmed_dma_bytes=dict(
            weights=4 * a.repeats * steps * a.kt * pt * panels,
            inputs=4 * a.repeats * panels * steps * ng * stride,
            outputs=a.repeats * output_bytes,
        ),
    )
    m["hash_request_samples"] = request_samples(m, initial)
    choices = hash_choices(m["hash_request_samples"])
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
    assert final["__l1_alloc_base"] <= final["__l1_end"], "Linked L1 overflow"
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
            l2_budget_upper_bound=tiling["l2_estimate"],
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
