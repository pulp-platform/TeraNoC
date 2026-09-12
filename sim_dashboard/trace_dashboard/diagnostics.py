"""Evidence-led benchmark diagnostics; associations are not causal proofs."""
from collections import defaultdict
from statistics import median


def benchmark_diagnostics(rows, meta, hash_result):
  bench = meta.get('benchmark')
  if not bench:
    return dict(available=False, reason='Benchmark boundaries are required.')
  start, end = bench
  grouped = defaultdict(lambda: defaultdict(list))
  for r in rows:
    if (r.get('phase') == 'bench' and 'g' in r and
        r['start'] >= start and r['end'] <= end):
      grouped[r['g']][r['kind']].append(r)
  if not grouped:
    return dict(available=False, reason='No per-group benchmark records.')
  expected = meta.get('expected_fmac_per_group', [])
  hashes = {g['g']: g for g in hash_result.get('groups', [])}
  result = []
  def total(rs, key):
    return sum(r.get(key, 0) for r in rs)
  def ratio(a, b):
    return a / b if b else None
  def covered(rs):
    intervals = sorted((r['start'], r['end']) for r in rs)
    return bool(intervals and intervals[0][0] == start and
                intervals[-1][1] == end and all(
                  a[1] == b[0] for a, b in zip(intervals, intervals[1:])))
  for g in range(meta['mesh'][0] * meta['mesh'][1]):
    rs = grouped[g]
    work = sorted(rs['work'], key=lambda r: r['end'])
    assigned = expected[g] if g < len(expected) else None
    done = total(work, 'fmac')
    cumulative, completion = 0, None
    if assigned and done == assigned and covered(work):
      for r in work:
        cumulative += r['fmac']
        if cumulative >= assigned:
          completion = [r['start'], r['end']]
          break
    entries, mshr = rs['entry'], rs['mshr']
    occupied = total(entries, 'occupied')
    h = hashes.get(g, {})
    score = {}
    for key, candidates in [('a', 'singles'), ('w', 'weights')]:
      current = h.get('current_' + key)
      best = h.get(candidates, [])
      if current and best:
        score[key] = dict(current=current['concurrent_banks'],
                          best=best[0]['concurrent_banks'])
    life = meta.get('mshr_lifetime', {}).get(
      f"{g // meta['mesh'][1]},{g % meta['mesh'][1]}", {})
    result.append(dict(g=g, assigned=assigned, fmac=done, completion=completion,
      progress=ratio(done, assigned), occupancy=ratio(total(mshr, 'occupied'),
      total(mshr, 'capacity')), peak=max((r['peak'] for r in mshr), default=None),
      full_cycles=total(mshr, 'full') if mshr else None,
      held_share=ratio(total(entries, 'held'), occupied),
      cached_share=ratio(total(entries, 'cached'), occupied),
      hash=score, locality=h.get('locality'),
      lifetime={key: ratio(life.get(key + '_sum', 0), life.get(key + '_n', 0))
                for key in ('hold', 'flight', 'drain')},
      work_coverage=covered(work), mshr_coverage=covered(mshr)))
  tail = None
  tail_status = "incomplete"
  completion_summary = None
  if len(result) >= 3 and all(g['completion'] for g in result):
    ends = sorted(g['completion'][1] for g in result)
    completion_summary = dict(first_end=ends[0], last_end=ends[-1],
      cohorts=[dict(end=e, groups=[g['g'] for g in result if g['completion'][1] == e])
               for e in sorted(set(ends))])
    cutoff = ends[-3]
    # If more than two groups finish together, compare the final cohort with
    # the preceding completion cohort instead of reporting missing data.
    if cutoff == ends[-1] and len(set(ends)) > 1:
      cutoff = sorted(set(ends))[-2]
    tail_status = "no_resolved_tail"
    late = [g for g in result if g['completion'][1] > cutoff]
    if late:
      tail_status = "measured"
      remaining = 0
      for g in result:
        done = total([r for r in grouped[g['g']]['work'] if r['end'] <= cutoff], 'fmac')
        g['progress_at_tail'] = ratio(done, g['assigned'])
        remaining += g['assigned'] - done
      tail = dict(start=cutoff, end=end, groups=[g['g'] for g in late],
        cycle_fraction=(end-cutoff)/(end-start),
        remaining_work_fraction=remaining/sum(g['assigned'] for g in result))
  holds = [g['held_share'] for g in result if g['held_share'] is not None]
  med = median(holds) if holds else None
  suspects = [g['g'] for g in result if g['held_share'] is not None and
              g['held_share'] > 0.5 and g['held_share'] > 2 * med]
  matched = [g for g in result if g['hash'] and all(
    s['current'] >= s['best'] - 1e-9 for s in g['hash'].values())]
  return dict(available=True, benchmark=bench, groups=result, tail=tail, tail_status=tail_status,
    completion_summary=completion_summary,
    median_held_share=med, hold_outliers=suspects,
    hash_matches_best_groups=[g['g'] for g in matched],
    notes=[
      'Benchmark scope, independent of the phase and time selectors. Completion is an interval containing the final assigned FMAC, not an exact kernel-return cycle.',
      'Held means a valid WAIT_RESP entry whose fetch has not been issued. It includes subscriber collection and any delay before replay acceptance; it is not time waiting for a memory response.',
      'Full cycles mean the whole MSHR table is full. Zero full cycles does not rule out an individual bank or allocation-port conflict.',
      'Hash scores model simultaneous accesses; equal best spread does not prove optimal runtime. Locality is modeled from operand addresses and workload partition.',
      'Lifetime hold/flight/drain averages come from final MSHRLIFE counters for the whole simulation, not isolated benchmark windows. They cover MSHR-tracked remote entries only, excluding local and bypassed traffic. Missing counters remain unavailable.',
      'Confirm causality with controlled runs changing one factor at a time: hold window/subscriber policy, operand placement, then a hash candidate. Keep workload and correctness checks identical.'
    ])
