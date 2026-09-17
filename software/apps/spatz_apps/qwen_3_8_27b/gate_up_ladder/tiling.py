"""Mesh-aware storage budgets and exact, burst-friendly FP16 vector tails."""


def ceildiv(n, d):
    return (n + d - 1) // d


def vectors(start, count, maximum=32):
    """Yield (column, VL) without crossing a 64-byte tile bank stripe.

    Bases and row strides are 64-byte aligned. A lone halfword aligns an odd
    column to a memory word; all longer requests are word granular. Lengths
    of at least four halves are therefore eligible contained bursts.
    """
    while count:
        size = min(count, maximum, 32 - start % 32)
        if start % 2:
            size = 1
        elif size > 1:
            size -= size % 2
        yield start, size
        start += size
        count -= size


def budget(mesh, batch, hidden, width, blocks, kt, pt):
    groups = mesh * mesh
    span = pt // blocks
    panels = ceildiv(width // blocks, span)
    steps = ceildiv(hidden, kt)
    stride = (ceildiv(batch * kt * 2, 1024) | 1) * 512
    buffers = 4 * kt * pt + 4 * groups * stride + 2 * batch * pt
    # Leave room for stacks, CSR/status arrays, runtime and alignment holes.
    reserve = groups * 16 * 2048
    events = 48 * panels * steps
    l2 = 4 * steps * kt * pt * panels + 2 * steps * groups * stride
    l2 += 4 * panels * batch * pt + 1024 * 1024
    return dict(kt=kt, pt=pt, panel_span=span, panels=panels, steps=steps,
                x_stride_elements=stride, matrix_buffers=buffers,
                runtime_reserve=reserve, event_bytes=events,
                l1_estimate=buffers + reserve + events,
                l1_capacity=groups * 256 * 1024, l2_estimate=l2)


def select(mesh, batch, hidden, width, blocks, kt=0, pt=0):
    """Prefer a full output panel, then fit the mesh's reduction-tile target.

    Explicit dimensions are checked rather than silently reduced. The default
    targets (40/160) divide K=5120; smaller budgets may need a final K tail.
    """
    assert mesh in (4, 8) and width % blocks == 0
    widths = [pt] if pt else list(dict.fromkeys([width, 8192, 4096, 2048, 1024]))
    target = 40 if mesh == 4 else 160
    lengths = [kt] if kt else list(range(min(target, hidden) // 8 * 8, 0, -8))
    for columns in widths:
        if columns <= 0 or columns > width or columns % blocks or columns % 32:
            continue
        for reduction in lengths:
            if reduction <= 0:
                continue
            result = budget(mesh, batch, hidden, width, blocks, reduction, columns)
            if result['l1_estimate'] <= result['l1_capacity'] and result['l2_estimate'] <= 512 * 1024**2:
                return result
    raise ValueError('Requested tiling does not fit the L1/L2 budgets or alignment contract')
