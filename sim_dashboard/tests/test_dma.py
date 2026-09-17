"""DMA units and compound-workload accounting must not invent measurements."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from trace_dashboard.model import validate, identity
from trace_dashboard.cli import expected_fmac_total
from trace_dashboard.analysis import roofline
from trace_dashboard.diagnostics import benchmark_diagnostics


class StreamingTests(unittest.TestCase):
  def test_software_dma_units(self):
    row = dict(kind='dma', start=10, end=30, scope='global',
               measurement='software', wait_check_cycles=12)
    validate(row)
    for extra in [dict(g=0), dict(wait_check_cycles=21), dict(completed_bytes=64),
                  dict(active_cycles=0), dict(programmed_bytes=-1)]:
      with self.assertRaises(ValueError):
        validate(dict(row, **extra))

  def test_channel_identity(self):
    row = dict(kind='dma', start=0, end=100, scope='channel',
               channel=0, measurement='model', completed_bytes=64, active_cycles=50)
    validate(row)
    self.assertNotEqual(identity(row), identity(dict(row, channel=1)))

  def test_fmac_progress_is_not_useful_flops(self):
    meta = dict(shape=[2, 5120, 17408], workload=dict(executed_fmac=503316480))
    self.assertEqual(expected_fmac_total(meta), 503316480)
    self.assertEqual(expected_fmac_total(dict(shape=[2, 128, 16], fmac_reduction_steps=127)), 4064)

  def test_compound_roofline(self):
    root = Path(__file__).resolve().parents[2]
    peak = root / 'roofline/peaks/terapool_spatz4_fpu.json'
    meta = dict(mesh=[4, 4], shape=[2, 5120, 17408], precision='fp16',
      cycles_per_pass=1207704, repetitions=1, benchmark=[100, 1207804],
      workload=dict(useful_flops=4*2*5120*17408, definition='Gate + Up'))
    result = roofline([], meta, peak, [])
    self.assertAlmostEqual(result['benchmark_compute_utilization'], 0.1441412796513053)
    self.assertEqual(result['ideal_cycles'], 174080)
    meta['compute_precision'] = 'fp32'
    widened = roofline([], meta, peak, [])
    self.assertEqual(widened['ideal_cycles'], 348160)

  def test_missing_mshr_counters_stay_unavailable(self):
    rows = [dict(kind='mshr', phase='bench', g=0, start=0, end=100,
                 occupied=0, capacity=6500)]
    result = benchmark_diagnostics(rows, dict(mesh=[1, 1], benchmark=[0, 100]), {})
    self.assertIsNone(result['groups'][0]['peak'])
    self.assertIsNone(result['groups'][0]['full_cycles'])


if __name__ == '__main__':
  unittest.main()
