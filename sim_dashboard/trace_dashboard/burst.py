"""Versioned request model for unmasked, unit-stride GEMM loads (vstart=0).

Mirror software/runtime/gemm_burst.h. Addresses are bytes; emitted requests are
(word address, word count). This models requests, not their arrival timing.
"""
PROFILES = ('tile-contained-v1', 'aligned-v1')


def requests(address, size, *, profile, tile_words, max_words, lanes, rob_depth,
             enabled=True):
  if profile not in PROFILES:
    raise ValueError('Unknown burst model: '+str(profile))
  if (any(not isinstance(v, int) or v <= 0 for v in
          (tile_words, max_words, lanes, rob_depth)) or address < 0 or size < 0):
    raise ValueError('Invalid burst geometry, address or load size')
  if not size:
    return []
  if tile_words & (tile_words-1) or max_words & (max_words-1):
    raise ValueError('Tile and maximum burst words must be powers of two')
  word = address // 4
  left = tile_words - word % tile_words
  eligible = (enabled and address % 4 == 0 and size % 4 == 0 and
              8 <= size <= rob_depth * lanes * 4)
  if profile == 'aligned-v1':
    eligible = eligible and address % (max_words * 4) == 0
  else:
    eligible = (eligible and (max_words % lanes == 0 or size <= max_words * 4) and
                (size <= left * 4 or (address % (lanes * 4) == 0 and
                 tile_words % lanes == 0 and max_words % lanes == 0)))
  remaining = (address % 4 + size + 3) // 4
  result = []
  while remaining:
    count = min(remaining, max_words)
    if profile == 'tile-contained-v1':
      count = min(count, tile_words - word % tile_words)
    if not eligible or count > rob_depth:
      count = 1
    result.append((word, count))
    word += count
    remaining -= count
  return result
