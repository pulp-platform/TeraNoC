# OOC runs killed 2026-09-04 23:05 (ran under the BROKEN 15 pF base_ooc.sdc)

All four predate the SDC fix at 19:44, so any WNS from them is invalid: 94% of a measured path
was output load. The INSTCNT traces below ARE still meaningful -- they come from initial_map,
before any timing-driven optimisation, which the output-load bug cannot reach.

## rt_f4all_8p0
```
log:      ooc_rt_f4all_8p0.log (17M)
last:     2026-09-04 23:18
src:      /usr/scratch/fenga3/zexifu/teranoc_spatz_backend/tsmc7/fusion/ooc/src/mshr_f4all.sv  md5=69a233459620d346
phase:     initial_map / High-Level Optimization and Technology Mapping
instcnt:  2268758 2268758 2265183 2265183 1088754 1088754 
stages:   analysis constraints elaboration setup_library synthesis 
```

## gate_6fee18d8_2p0
```
log:      ooc_gate_6fee18d8_2p0.log (17M)
last:     2026-09-04 23:16
src:      the backend checkout's own file (f308f8b694666d6d)
phase:     initial_map / High-Level Optimization and Technology Mapping
instcnt:  1966499 1966499 1962958 1962958 1251990 1251990 
stages:   analysis constraints elaboration setup_library synthesis 
```

## rt_f3a_8p0
```
log:      ooc_rt_f3a_8p0.log (17M)
last:     2026-09-04 23:17
src:      /usr/scratch/fenga3/zexifu/teranoc_spatz_backend/tsmc7/fusion/ooc/src/mshr_f3a.sv  md5=5a69117f1db4ce4f
phase:     logic_opto / Optimization (2)
instcnt:  1956735 1956735 1953353 1953353 1240806 1240806 1486562 1486562 1486491 1486491 1486700 1486700 1486698 
stages:   analysis constraints elaboration setup_library synthesis 
```

## rt_clean_8p0
```
log:      ooc_rt_clean_8p0.log (17M)
last:     2026-09-04 23:24
src:      /usr/scratch/fenga3/zexifu/teranoc_spatz_backend/tsmc7/fusion/ooc/src/mshr_clean.sv  md5=ca4a07ef2de2eb35
phase:     logic_opto / Optimization (2)
instcnt:  2012906 2012906 2009363 2009363 832934 832934 1052687 1052687 1052381 1052381 1052580 1052580 1052579 
stages:   analysis constraints elaboration setup_library synthesis 
```


## What these traces changed

Two of the four had progressed past technology mapping into `logic_opto`, and that revealed the
F-series numbers quoted so far are **constant-propagation values, not final ones**:

| arm | const-prop | post-mapping | delta |
|---|---:|---:|---:|
| `rt_f3a` (F3a) | 1,240,806 | 1,486,698 | +19.8% |
| `rt_clean` (F6) | 832,934 | 1,052,579 | +26.4% |

So the headline "base_head 1,269,127 -> f6 832,934, -34.4%" is a **const-prop** comparison. After
mapping the gap narrows to -29.2% (1,486,698 -> 1,052,579). Mapping also does not preserve the
ranking margin, so any future comparison must state which phase it is taken at.

Worse, these post-mapping figures were produced under the broken 15 pF SDC. Technology mapping is
timing-aware, so its drive-strength choices were distorted by a load ~1000x too large -- the
+20/+26% rise is partly real mapping and partly that bug. They are recorded here as the
contaminated reference, NOT as a baseline. The three runs under the corrected SDC
(`base2_8p0`, `fix2_head_8p0`, `fix2_head_2p0`) are what will give the first clean post-mapping
comparison.

Cross-validation worth keeping: `base2_8p0` reproduced `base_head`'s const-prop count to the digit
(1,269,127), and the pre-simplification value too (1,981,738). The harness is reproducible, and the
SDC fix does not perturb the pre-timing phases -- as expected, since constant propagation runs
before any timing-driven optimisation.
