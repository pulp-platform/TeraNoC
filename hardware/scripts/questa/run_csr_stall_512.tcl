# Driver for the cfg_runtime=1 stall on 512x256x512 -- replaces run.tcl for this debug.
#
# WHY NOT run.tcl. That script does `log -r *` (every signal in a 256-core elaboration) and then
# `run -a`. Measured on build_4 on 2026-08-16: under 1000 cycles per 5 minutes and 306 MiB/min of
# WLF. The event worth seeing is at cyc 100,000, so that is 7-15 hours and 130-270 GB to reach a
# waveform whose interesting window is 70,000 cycles wide.
#
# WHAT THIS DOES INSTEAD. Fast-forward with NO logging, then log only group 0's MSHR / CSR file /
# barrier, then run through both events. Nothing is logged before cyc 40,000, so there is no history
# from the run-up -- that is the deliberate trade, and it is fine here because the run-up is healthy
# (93.5% util, zero dead periods) and already fully characterised by the batch arm.
#
#   phaseE1  MSHR on from reset          79,653 cyc     0 dead periods
#   hangiso  MSHR never enabled         168,919 cyc     3 dead periods   <- CSR RTL present, no stall
#   sweepCSR MSHR enabled by software   280,917 cyc   169 dead periods   <- what this run reproduces
#
# THE TWO EVENTS, and the contrast between them is the point:
#   cyc  44,000   93.5% -> 34.7%   a dip that RECOVERS
#   cyc 100,000   91.0% -> 11.3%   the collapse that does NOT
# Both fall inside the logged window below. After cyc 108,000 it sits at 0.1-0.9% for ~170,000
# cycles before finishing -- there is nothing in that tail, which is why this stops at 112,000.
#
# TIME CONVERSION for this TB: ns = 2*cyc + 10.

# ---- Phase 1: fast-forward to just before the recovering dip, logging NOTHING -----------------
# 40,000 cyc = 80,010 ns. The benchmark opens at cyc 23,931, so tracing is already live by here and
# the [MSHRCFG] guard line will have printed -- check the transcript for it before trusting the run.
puts "\[csr_stall\] phase 1: fast-forward to cyc 40,000 (80,010 ns), no waveform logging"
run 80010 ns

# ---- Phase 2: arm the narrow log --------------------------------------------------------------
# add wave logs from this instant in Questa; the explicit `log` calls make that independent of the
# Wave window and pick up anything the wave file groups but does not expand.
puts "\[csr_stall\] phase 2: arming narrow log on group 0 (MSHR / CSR file / barrier)"
do ../scripts/questa/wave_csr_stall_512.tcl
log -r $MSHR/*
log -r $CFG/*
log -r $BAR/*

# ---- Phase 3: through the dip AND the collapse ------------------------------------------------
# to 112,000 cyc = 224,010 ns.
puts "\[csr_stall\] phase 3: running to cyc 112,000 (224,010 ns) -- captures cyc 44,000 dip and cyc 100,000 collapse"
run 144000 ns

puts ""
puts "\[csr_stall\] STOPPED at cyc 112,000. The waveform now holds both events."
puts "  cyc  44,000 (~ 88,010 ns)   dip that RECOVERS   -- the control"
puts "  cyc 100,000 (~200,010 ns)   collapse            -- the failure"
puts ""
puts "  First thing to check, in this order:"
puts "   1. cfg_mshr_enable in group 0 -- when does it rise, and is it still high at cyc 100,000?"
puts "   2. status_q in the CSR file   -- sticky; non-zero means the config in effect is NOT the one"
puts "                                    software asked for (RANGE / BANK_BUSY / TIMEOUT_ZERO)."
puts "   3. mshr_q entry states        -- entries parked with sub_reqs_num < cfg_hold_subs_single are"
puts "                                    the prediction to kill first."
puts ""
puts "  'run -a' from here if you want the tail, but it is 170,000 cycles of 0.1-0.9% util."
