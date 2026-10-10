#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# SPDX-License-Identifier: Apache-2.0
#
# Host model of the fp16 vector library (qwen-common/qc_vec.h).
#
#   python3 vec_ref.py report              # accuracy of every routine over all fp16 inputs
#   python3 vec_ref.py header <out.h> [n]  # test vectors + bit-exact expected outputs
#
# Every routine is emulated OP BY OP in the order qc_vec.h issues them: each vector
# instruction rounds once to fp16 (an fma rounds once, as fpnew's fused FMA does). The
# device output must therefore match the emulation BIT FOR BIT; the float64 "truth" is only
# for the accuracy report. Constants are the fp16 values qc_vec.h loads (QC_K_* there).
import sys

import numpy as np

F16 = np.float16
F64 = np.float64


def h(v):
    """Round float64 -> fp16 (RNE)."""
    return np.asarray(v, dtype=F64).astype(F16)


def mul(a, b):
    return h(a.astype(F64) * b.astype(F64) if hasattr(b, "astype") else a.astype(F64) * b)


def add(a, b):
    return h(a.astype(F64) + (b.astype(F64) if hasattr(b, "astype") else b))


def fma(a, b, c):
    """a * b + c, one rounding."""
    bb = b.astype(F64) if hasattr(b, "astype") else F64(b)
    cc = c.astype(F64) if hasattr(c, "astype") else F64(c)
    return h(a.astype(F64) * bb + cc)


def k(v):
    """A constant as the device holds it: fp16."""
    return F64(F16(v))


# ---- constants (keep in sync with QC_K_* in qc_vec.h) ---------------------------------------
K_XMIN, K_XMAX = k(-18.0), k(11.0)  # exp(11) < 65504; exp(-18) rounds to exactly 0
K_INV32, K_MINV32 = k(1 / 32), k(-1 / 32)
K_C4, K_C3, K_C2 = k(1 / 24), k(1 / 6), k(0.5)  # Taylor: 1 + y + y^2/2 + y^3/6 + y^4/24
K_ABS_MAX = k(17.0)
K_R_A, K_R_B = k(-8 / 17), k(24 / 17)  # 1/d seed on [1, 2]: 24/17 - 8/17 d
K_BIG = k(16384.0)

# log1p(u) = u * (q0 + q1 u + q2 u^2 + q3 u^3) on [0, 1] (least squares on Chebyshev nodes)
_u = np.cos(np.pi * (np.arange(4000) + 0.5) / 4000) * 0.5 + 0.5
_q = np.polynomial.chebyshev.Chebyshev.fit(_u, np.log1p(_u) / _u, 3).convert(
    kind=np.polynomial.Polynomial).coef
K_Q = [k(c) for c in _q]


# ---- the routines, op by op -----------------------------------------------------------------
def _poly_sq(y):
    """exp(32 y) for y in [-0.54, 0.35]: degree-4 Taylor in y, then squared 5 times."""
    p = mul(y, K_C4)              # vfmul.vf
    p = add(p, K_C3)              # vfadd.vf
    p = fma(y, p, K_C2)           # vfmadd.vv p, y, C2   (p = y*p + C2)
    p = fma(y, p, 1.0)            # vfmadd.vv p, y, ONE
    p = fma(y, p, 1.0)            # vfmadd.vv p, y, ONE
    for _ in range(5):
        p = mul(p, p)             # vfmul.vv
    return p


def exp16(x):
    x = np.maximum(x, F16(K_XMIN))  # vfmax.vf
    x = np.minimum(x, F16(K_XMAX))  # vfmin.vf
    y = mul(x, K_INV32)             # vfmul.vf (exact)
    return _poly_sq(y)


def eneg16(x):
    """exp(-|x|)."""
    a = np.abs(x)                   # vfsgnjx.vv
    a = np.minimum(a, F16(K_ABS_MAX))  # vfmin.vf
    y = mul(a, K_MINV32)            # vfmul.vf (exact)
    return _poly_sq(y)


def sigmoid16(x):
    e = eneg16(x)
    d = add(e, 1.0)                 # vfadd.vf     d in (1, 2]
    r = mul(d, K_R_A)               # vfmul.vf
    r = add(r, K_R_B)               # vfadd.vf     r0 = 24/17 - 8/17 d
    t = mul(d, r)                   # vfmul.vv
    t = h(2.0 - t.astype(F64))      # vfrsub.vf    2 - d r0
    r = mul(r, t)                   # vfmul.vv     r1 = 1/d (one Newton step)
    t = np.maximum(x, F16(0.0))     # vfmax.vf
    e = fma(t, K_BIG, e)            # vfmacc.vf e, BIG, t : 1 for x > 0, e for x <= 0 (after min)
    e = np.minimum(e, F16(1.0))     # vfmin.vf
    return mul(r, e)                # vfmul.vv


def silu16(x):
    return mul(sigmoid16(x), x)     # vfmul.vv


def softplus16(x):
    e = eneg16(x)
    l = mul(e, K_Q[3])              # vfmul.vf
    l = add(l, K_Q[2])              # vfadd.vf
    l = mul(l, e)                   # vfmul.vv
    l = add(l, K_Q[1])
    l = mul(l, e)
    l = add(l, K_Q[0])
    l = mul(l, e)                   # log1p(e)
    t = np.maximum(x, F16(0.0))     # vfmax.vf
    return add(t, l)                # vfadd.vv


def rsqrt32(x):
    """Scalar fp32: bit seed + 3 Newton steps (qc_rsqrt_f32)."""
    x = np.float32(x)
    i = np.array([x], dtype=np.float32).view(np.uint32)[0]
    y = np.array([np.uint32(0x5F3759DF) - (i >> np.uint32(1))], dtype=np.uint32).view(np.float32)[0]
    hx = np.float32(0.5) * x
    for _ in range(3):
        y = np.float32(y * (np.float32(1.5) - np.float32(hx * y) * y))
    return y


ROUTINES = {
    "exp": (exp16, np.exp),
    "sigmoid": (sigmoid16, lambda x: 1 / (1 + np.exp(-x))),
    "silu": (silu16, lambda x: x / (1 + np.exp(-x))),
    "softplus": (softplus16, lambda x: np.log1p(np.exp(-np.abs(x))) + np.maximum(x, 0)),
}


def all_f16(lo, hi):
    v = np.arange(65536, dtype=np.uint32).astype(np.uint16).view(F16)
    v = v[np.isfinite(v)]
    return v[(v >= lo) & (v <= hi)]


def report():
    np.seterr(all="ignore")
    print("log1p q:", [float(q) for q in K_Q])
    for name, (emu, ref) in ROUTINES.items():
        x = all_f16(-20.0, 11.0 if name == "exp" else 20.0)
        got = emu(x).astype(F64)
        tru = ref(x.astype(F64))
        rel = np.abs(got - tru) / np.maximum(np.abs(tru), 1e-3)
        bad = np.argmax(rel)
        print(f"{name:9} n={x.size:6} max rel err {rel.max():.2e} at x={float(x[bad]):.4g} "
              f"(got {got[bad]:.5g}, want {tru[bad]:.5g}); mean {rel.mean():.2e}")
    for v in (1e-6, 0.37, 1.0, 4096.0, 1e6):
        print(f"rsqrt32({v}) = {rsqrt32(v):.8g}  want {1 / np.sqrt(v):.8g}")


def c_array(name, arr):
    bits = arr.astype(F16).view(np.uint16)
    body = ",".join(f"0x{b:04x}" for b in bits)
    return f"static const uint16_t {name}[{len(bits)}] = {{{body}}};\n"


def header(path, n):
    np.seterr(all="ignore")
    rng = np.random.default_rng(7)
    # A spread over the interesting range plus the edges every routine clamps or selects at.
    edges = np.array([0.0, -0.0, 1e-4, -1e-4, 6e-5, -6e-5, 1.0, -1.0, 11.0, -17.0, 12.0, -18.0,
                      20.0, -20.0, 60000.0, -60000.0], dtype=F64)
    x = np.concatenate([edges, rng.uniform(-20, 20, n - edges.size)]).astype(F16)
    out = ["// GENERATED by qwen-common/script/vec_ref.py -- do not hand-edit.\n",
           "#ifndef QC_VEC_TEST_DATA_H\n#define QC_VEC_TEST_DATA_H\n#include <stdint.h>\n",
           f"#define QC_TEST_N {n}\n", c_array("qc_test_x", x)]
    for name, (emu, _) in ROUTINES.items():
        out.append(c_array(f"qc_test_{name}", emu(x)))
    out.append(f"#define QC_TEST_SUMSQ {float(np.sum(x.astype(F64) ** 2)):.9e}f\n")
    out.append("#endif\n")
    with open(path, "w") as f:
        f.write("".join(out))
    print(f"wrote {path} ({n} vectors)")


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "report":
        report()
    elif len(sys.argv) >= 3 and sys.argv[1] == "header":
        header(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 512)
    else:
        print(__doc__ if __doc__ else "usage: vec_ref.py report | header <out.h> [n]")
        sys.exit(2)
