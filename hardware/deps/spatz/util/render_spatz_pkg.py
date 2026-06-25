#!/usr/bin/env python3
# Copyright 2023 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Minimal renderer for the vendored Spatz vector-IP package.
#
# Replaces the upstream Spatz `clustergen` flow for the single artifact TeraNoC
# needs: hw/ip/spatz/src/generated/spatz_pkg.sv, rendered from the self-contained
# Mako template spatz_pkg.sv.tpl. The template only references cfg['mempool'],
# cfg['spatz_fpu'], cfg['n_fpu'], cfg['n_ipu'], cfg['vlen']; for the mempool
# branch N_FPU/N_IPU/VLEN/RVF/RVD are emitted as `ifdef-guarded localparams, so
# their concrete values are injected at vlog time via -D defines from the config
# .mk knobs -- this renderer just selects the mempool branch.

import argparse
import pathlib
import sys

import hjson
from mako.template import Template


def main():
    ap = argparse.ArgumentParser(description="Render spatz_pkg.sv from its Mako template.")
    ap.add_argument("-c", "--cfg", required=True, help="hjson config (provides cfg dict)")
    ap.add_argument("-t", "--tpl", required=True, help="spatz_pkg.sv.tpl template")
    ap.add_argument("-o", "--out", required=True, help="output spatz_pkg.sv path")
    args = ap.parse_args()

    with open(args.cfg) as f:
        cfg = hjson.load(f)

    rendered = Template(filename=args.tpl).render(cfg=cfg)

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(rendered)
    print(f"render_spatz_pkg: wrote {out} ({len(rendered)} bytes)", file=sys.stderr)


if __name__ == "__main__":
    main()
