"""Check exact coverage, RTL burst eligibility and both meshes' storage limits."""
import ctypes
from pathlib import Path
import subprocess
import tempfile
import unittest

from tiling import select, vectors


class TilingTests(unittest.TestCase):
    def test_full_width_defaults(self):
        for mesh, kt in [(4, 40), (8, 160)]:
            plan = select(mesh, 1, 5120, 17408, mesh * mesh * 16)
            self.assertEqual((plan['kt'], plan['pt'], plan['panels']), (kt, 17408, 1))
            self.assertEqual(plan['steps'] * kt, 5120)

    def test_batch_ladder_fits(self):
        for mesh in (4, 8):
            for batch in (1, 2, 4, 8, 16, 32, 64, 128):
                for blocks in (4, 8, 64, 128, 256, mesh * mesh * 16):
                    plan = select(mesh, batch, 5120, 17408, blocks)
                    self.assertLessEqual(plan['l1_estimate'], plan['l1_capacity'])
                    self.assertLessEqual(plan['l2_estimate'], 512 * 1024**2)
                    self.assertEqual(plan['pt'] % 32, 0)
                    self.assertEqual(plan['pt'] % blocks, 0)

    def test_explicit_overflow_and_reduction_tail(self):
        for mesh, kt in [(4, 64), (8, 256)]:
            with self.assertRaises(ValueError):
                select(mesh, 1, 5120, 17408, mesh * mesh * 16, kt, 17408)
        for mesh, kt, steps, tail in [(4, 48, 107, 32), (8, 192, 27, 128)]:
            p = select(mesh, 1, 5120, 17408, mesh * mesh * 16, kt, 17408)
            self.assertEqual(p['steps'], steps)
            self.assertEqual(5120 - (steps - 1) * kt, tail)

    def test_vector_coverage_and_production_burst_contract(self):
        runtime = Path(__file__).resolve().parents[4] / 'runtime'
        with tempfile.TemporaryDirectory(prefix='qwen_tail_test_') as temp:
            root = Path(temp)
            source = root / 'check.c'
            source.write_text('#define GEMM_BURST_TILE_WORDS 16\n'
                              '#define GEMM_BURST_LANES 4\n'
                              '#include "gemm_burst.h"\n'
                              'int eligible(unsigned a,unsigned n) { return gemm_burst_eligible(a,n); }\n')
            subprocess.run(['cc', '-shared', '-fPIC', '-I' + str(runtime),
                            str(source), '-o', str(root / 'check.so')], check=True)
            eligible = ctypes.CDLL(str(root / 'check.so')).eligible
            for start in range(64):
                for count in (1, 2, 3, 4, 8, 17, 32, 34, 68, 136, 272):
                    segments = list(vectors(start, count))
                    covered = [c for col, vl in segments for c in range(col, col + vl)]
                    self.assertEqual(covered, list(range(start, start + count)))
                    for col, vl in segments:
                        self.assertLessEqual(vl, 32)
                        if vl >= 4:
                            self.assertTrue(eligible(2 * col, 2 * vl))


if __name__ == '__main__':
    unittest.main()
