#!/usr/bin/env python3
"""Check that every vector load the kernel emits is burst-eligible.

The kernel's qwen_burst_vl() is the one subtle thing in this app, and getting it
wrong is SILENT: the loads still return the right data, they just stop bursting,
and only a cycle count says so. This replays the p-loop for the production shapes
against a port of runtime/gemm_burst.h's eligibility predicate.

    python3 script/test_burst_vl.py

It compiles nothing and runs nothing on the target -- it is a check of the two
address rules, not of the kernel binary.
"""
import sys

# VLSU / TCDM geometry, terapool_spatz4_fpu. Mirrors the GEMM_BURST_* defaults.
TILE_WORDS, LANES, ROB_DEPTH, MAX_WORDS, ELEM_BYTES = 16, 4, 32, 16, 2
STRIPE_E = TILE_WORDS * 4 // ELEM_BYTES  # 32 fp16 elements per 64-byte stripe


def eligible(addr, nbytes):
    """Port of gemm_burst_eligible() in software/runtime/gemm_burst.h."""
    tile_left = TILE_WORDS - (addr // 4) % TILE_WORDS
    return (addr % 4 == 0 and nbytes % 4 == 0 and nbytes >= 8
            and nbytes <= ROB_DEPTH * LANES * 4
            and (MAX_WORDS % LANES == 0 or nbytes <= MAX_WORDS * 4)
            and (nbytes <= tile_left * 4
                 or (addr % (LANES * 4) == 0 and TILE_WORDS % LANES == 0
                     and MAX_WORDS % LANES == 0)))


def burst_vl(p, p_end):
    """Port of qwen_burst_vl() in kernel/qwen-fmatmul.c. The cap is
    UNCONDITIONAL so that every core emits the same vector sequence -- see the
    comment there; a per-core-varying trip count breaks the MSHR cohort."""
    left = p_end - p
    to_stripe_end = STRIPE_E - (p % STRIPE_E)
    return to_stripe_end if left > to_stripe_end else left


def sweep(p_total, blocks, vlmax, fixed=True):
    """Walk every core's column block. Buffer bases are mesh-sweep aligned and row
    strides are whole stripes, so byte address == element index * 2 mod 64."""
    span, bad, total = p_total // blocks, 0, 0
    for k in range(blocks):
        p, p_end = k * span, (k + 1) * span
        while p < p_end:
            gvl = min(vlmax, burst_vl(p, p_end) if fixed else p_end - p)
            total += 1
            bad += not eligible(p * ELEM_BYTES, gvl * ELEM_BYTES)
            p += gvl
    return bad, total


def ldp(p_total, blocks):
    """Port of QWEN_LDP in main.c: round the stored width up so that every core's
    span is a multiple of QWEN_SPAN_ALIGN elements (and the row stride a whole
    number of stripes)."""
    unit = max(blocks * SPAN_ALIGN, STRIPE_E)
    return (p_total + unit - 1) // unit * unit


SPAN_ALIGN = 4  # QWEN_SPAN_ALIGN: 8 bytes, the two-word burst floor

# (name, P, column blocks, VLMAX). VLMAX = VLEN * LMUL / 16, and gemm_config.h's
# GEMM_LMUL gives m8 at KERNEL_SIZE 1 and 2, m4 at 4, m2 at 8.
CASES = [
    ("4x4  B=1  (KS=1, 256 blocks)", 17408, 256, 256),
    ("4x4  B=2  (KS=1, 128 blocks)", 17408, 128, 256),
    ("4x4  B=4  (KS=1,  64 blocks)", 17408, 64, 256),
    ("8x8  B=1  (KS=1, 1024 blocks)", 17408, 1024, 256),
    ("8x8  B=4  (KS=1, 256 blocks)", 17408, 256, 256),
]

failed = 0
for name, p_total, blocks, vlmax in CASES:
    padded = ldp(p_total, blocks)
    bad, total = sweep(padded, blocks, vlmax)
    raw, _ = sweep(p_total, blocks, vlmax, fixed=False)
    pad_pct = 100.0 * padded / p_total - 100.0
    status = "ok" if bad == 0 else "FAIL"
    failed += bad != 0
    print(f"{status:4}  {name}: ldp={padded} (+{pad_pct:.1f}% pad), "
          f"{padded // blocks} cols/core, {total} vectors, {bad} non-burst "
          f"(unpadded + parent kernel: {raw} non-burst)")

# The stripe cap must be inert where p_start is already stripe aligned, or this
# kernel would stop being comparable to its burst-merge parent.
a = sweep(256, 8, 64, fixed=True)
b = sweep(256, 8, 64, fixed=False)
status = "ok" if a == b else "FAIL"
failed += a != b
print(f"{status:4}  256x256x256 anchor: unchanged by the stripe cap ({a} vs {b})")

sys.exit(1 if failed else 0)
