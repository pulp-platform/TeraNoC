"""One logical dataset shared across partitions, meshes and batch prefixes."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def create(out, batch, hidden, width, values="grid", pattern="random", seed=20260917):
    out.mkdir(parents=True, exist_ok=False)
    rng = np.random.default_rng(seed)
    x = (
        rng.uniform(-0.25, 0.25, (batch, hidden))
        if values == "dense"
        else rng.integers(-4, 5, (batch, hidden)) / 16
    ).astype("<f2")
    if pattern == "zero":
        x[:] = 0
    elif pattern == "unit":
        x[:] = 0
        x[:, hidden - 1] = 1
    x.tofile(out / "x.bin")
    for stage, offset in [("gate", 1), ("up", 2)]:
        rng = np.random.default_rng(seed + offset)
        wide = np.zeros((batch, width), np.float32)
        half = np.zeros_like(wide, np.float16)
        with (out / f"{stage}.bin").open("wb") as stream:
            for k in range(hidden):
                weights = (
                    rng.uniform(-0.0625, 0.0625, width)
                    if values == "dense"
                    else rng.integers(-4, 5, width) / 64
                ).astype("<f2")
                stream.write(weights.tobytes())
                product = x[:, k, None].astype(np.float64) * weights.astype(np.float64)
                wide = (wide.astype(np.float64) + product).astype(np.float32)
                half = (half.astype(np.float64) + product).astype(np.float16)
        wide.tofile(out / f"expected_{stage}.bin")
        half.astype("<f4").tofile(out / f"expected_fp16_{stage}.bin")
    manifest = dict(
        batch=batch,
        hidden=hidden,
        intermediate=width,
        values=values,
        pattern=pattern,
        seed=seed,
        files={p.name: sha(p) for p in out.glob("*.bin")},
    )
    (out / "dataset.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--hidden", type=int, default=5120)
    ap.add_argument("--intermediate", type=int, default=17408)
    ap.add_argument("--values", choices=["grid", "dense"], default="grid")
    ap.add_argument("--pattern", choices=["random", "zero", "unit"], default="random")
    a = ap.parse_args()
    print(json.dumps(create(a.out, a.batch, a.hidden, a.intermediate, a.values, a.pattern)))
