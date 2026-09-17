"""Score explicit adapter-supplied remote request cohorts, not a GEMM layout guess."""


def explore(meta):
  source = meta['hash_samples']
  banks, entries = source['banks'], source['entries']
  if banks != 16 or entries != 64 or source.get('mode') != 'simple':
    raise ValueError('Explicit hash samples require the declared 16-bank simple hash')
  groups = []
  for group in source['groups']:
    cohorts = group['cohorts']
    if not cohorts:
      raise ValueError('Hash samples require cohorts, including empty remote sets')

    def score(cls, shift, bits):
      hist, reached = [0]*banks, 0
      for cohort in cohorts:
        hits = [0]*banks
        for word in set(cohort[cls]):
          if not isinstance(word, int) or word < 0:
            raise ValueError('Hash samples must contain nonnegative word addresses')
          hits[(((word >> shift) << bits) | ((word >> 4) & bits)) & 15] += 1
        reached += sum(x > 0 for x in hits)
        hist = [a+b for a, b in zip(hist, hits)]
      return dict(shift=shift, burst_bits=bits, histogram=hist,
                  concurrent_banks=reached/len(cohorts),
                  fraction=reached/(len(cohorts)*banks))

    choices = {}
    for cls, bits_range in [('single', [0]), ('burst', [0, 1])]:
      choices[cls] = sorted(
        [score(cls, shift, bits) for bits in bits_range
         for shift in range(4+bits, 11)],
        key=lambda r: (-r['concurrent_banks'], max(r['histogram']), r['shift'], r['burst_bits']))
    a, b, bits = group['current']
    if not 4 <= a <= 10 or bits not in (0, 1) or not 4+bits <= b <= 10:
      raise ValueError('Captured hash settings outside supported CSR range')
    hits = [dict(single=0, burst=0) for _ in range(banks)]
    # Show the first cohort containing remote requests; no remote requests
    # produces a real empty modeled set, distinct from unavailable entry probes.
    first = next((c for c in cohorts if c['single'] or c['burst']), cohorts[0])
    for cls, shift, bb in [('single', a, 0), ('burst', b, bits)]:
      for word in set(first[cls]):
        hits[(((word >> shift) << bb) | ((word >> 4) & bb)) & 15][cls] += 1
    groups.append(dict(g=group['g'], sharing=group.get('sharing'),
      locality=group.get('locality'), current_a=score('single', a, 0),
      current_w=score('burst', b, bits), singles=choices['single'][:5],
      weights=choices['burst'][:5],
      request_counts=dict(single=sum(len(c['single_b']) for c in cohorts),
                          burst=sum(len(c['burst']) for c in cohorts)),
      concurrency=dict(step=first.get('step', 0), ways=entries//banks, banks=hits,
        busiest=max(sum(c.values()) for c in hits),
        over_ways=sum(sum(c.values()) > entries//banks for c in hits))))
  return dict(available=True, groups=groups, banks=banks, entries=entries,
    overflow_entries=source.get('overflow_entries', 0),
    active_groups=len(groups), mesh_groups=meta['mesh'][0]*meta['mesh'][1],
    sampled_steps=source['sampled_steps'], total_steps=source['total_steps'],
    burst_model=source['burst_model'], burst_eligible=any(
      g['request_counts']['burst'] for g in groups),
    note=source['note'] + ' Remote requests only. Empty distributions mean this sample '
      'bypasses the group MSHR through locality. Static cohorts assume simultaneous '
      'arrival; bank spread does not predict speedup. Actual entry occupancy requires entry probes.')
