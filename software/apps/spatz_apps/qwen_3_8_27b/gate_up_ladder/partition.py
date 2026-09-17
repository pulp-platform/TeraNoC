"""Read the production GEMM policy and describe full-shape core ownership."""
import json
import subprocess
from pathlib import Path


def select(runtime, out, mesh, batch, hidden, width):
    source = out / "partition_check.c"
    source.write_text(
        """#include <stdio.h>
#include "gemm_config.h"
int main(void) {
  printf("{\\"ks\\":%u,\\"decode\\":%u,\\"share_a\\":%u,"
         "\\"share_b\\":%u,\\"pblocks\\":%u}\\n",
         KERNEL_SIZE, MATMUL_DECODE_SPLIT, GEMM_SHARE_A(KERNEL_SIZE),
         GEMM_SHARE_B(KERNEL_SIZE), GEMM_PBLOCKS(KERNEL_SIZE));
}
"""
    )
    command = [
        "cc",
        "-std=c11",
        "-O2",
        "-I" + str(runtime),
        f"-DNUM_GROUPS={mesh*mesh}",
        f"-DNUM_CORES={mesh*mesh*16}",
        f"-DGEMM_M={batch}",
        f"-DGEMM_N={hidden}",
        f"-DGEMM_P={width}",
        "-DGEMM_ELEM_BYTES=2",
        "-DVLEN=512",
        str(source),
        "-o",
        str(out / "partition_check"),
    ]
    subprocess.run(command, check=True)
    policy = json.loads(subprocess.check_output([str(out / "partition_check")]))
    policy["command"] = command
    return policy


def assignments(mesh, batch, width, policy, mapping):
    cores = mesh * mesh * 16
    result = []
    ks = min(batch, 4) if mapping == "register" else policy["ks"]
    blocks = cores if mapping == "register" else policy["pblocks"]
    for cid in range(cores):
        g, local = divmod(cid, 16)
        if mapping == "register":
            start, end, block = 0, batch, cid
        elif policy["decode"]:
            chunks = batch // ks
            start = (cid % chunks) * ks
            end, block = start + ks, cid // chunks
        else:
            group_rows = batch // (mesh * mesh)
            row_chunks = group_rows // ks
            if row_chunks < 16:
                start = g * group_rows + local // blocks * ks
                end, block = start + ks, local % blocks
            else:
                start = g * group_rows + local * (group_rows // 16)
                end, block = start + group_rows // 16, 0
        result.append(
            dict(
                core=cid,
                group=g,
                row_start=start,
                row_end=end,
                pblock=block,
                col_start=block * (width // blocks),
                col_end=(block + 1) * (width // blocks),
            )
        )
    # Coverage is checked independently of the target's loop implementation.
    coverage = [[0] * blocks for _ in range(batch)]
    for a in result:
        assert (a["row_end"] - a["row_start"]) % ks == 0
        for row in range(a["row_start"], a["row_end"]):
            coverage[row][a["pblock"]] += 1
    assert all(x == 1 for row in coverage for x in row)
    return dict(ks=ks, pblocks=blocks, pspan=width // blocks, assignments=result)
