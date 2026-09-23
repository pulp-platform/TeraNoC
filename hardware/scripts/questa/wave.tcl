# Copyright 2024 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

onerror {resume}
quietly WaveActivateNextPane {} 0

# Add a vector of the core's utilization signals to quickly get an overview of the systems activity
set num_cores [examine -radix dec mempool_pkg::NumCores]

# Per-core Snitch stall overview (defined in hardware/tb/mempool_tb.sv).
# Stall judgement excludes WFI: core_stall = i_snitch.stall & ~wfi (WFI-idle cores not counted).
#   core_stall_count      : # cores stalled (non-WFI) this cycle (analog overview).
#   core_stall            : 1 bit/core, high while that core is stalled and not in WFI.
#   core_stall_long_count : # cores stalled (non-WFI) continuously > StallLongThreshold cycles.
#   core_stall_long       : 1 bit/core, the sticky long-stall flag (the "stuck a while" view).
#   core_stall_cnt        : per-core continuous-stall length (saturating) — how long it's stuck.
#   wfi                   : raw WFI vector, kept for reference.
add wave -noupdate -group Core_Stall -color {Orange Red} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/core_stall_count
add wave -noupdate -group Core_Stall /mempool_tb/core_stall
add wave -noupdate -group Core_Stall -color {Orange Red} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/core_stall_long_count
add wave -noupdate -group Core_Stall /mempool_tb/core_stall_long
add wave -noupdate -group Core_Stall -radix unsigned /mempool_tb/core_stall_cnt
add wave -noupdate -group Core_Stall /mempool_tb/wfi

# Benchmark phase marker. A test that writes the phase number to the `trace` CSR
# (0x7d0) -- e.g. sp-mshr-burst-test via phase_begin()/phase_end() -- shows here as
# a 1..N staircase per core (0 = idle), so you can read which test phase the sim is
# in straight off the waveform. csr_trace_any_global = profiling window active.
add wave -noupdate -group Benchmark_Phase -color {Gold} -format Analog-Step -height 60 -max 16 -radix unsigned /mempool_tb/core_bench_phase
add wave -noupdate -group Benchmark_Phase /mempool_tb/csr_trace_any_global

add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/snitch_utilization
add wave -noupdate -group Utilization /mempool_tb/instruction_handshake
add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/lsu_utilization
add wave -noupdate -group Utilization /mempool_tb/lsu_handshake
add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/lsu_pressure
add wave -noupdate -group Utilization /mempool_tb/lsu_request

# Fleet-wide Spatz FPU utilization (exists only under TARGET_SPATZ; sim-only TB block).
# fpu_busy_count: analog "how many FPUs are busy right now". fpu_busy: 256-bit per-core
# busy pattern (bit i == hart i == (group<<4)|tile) -- expand to see each core's busy
# pattern over time. fpu_busy_group: per-group counts (spot group skew).
if {![catch {examine /mempool_tb/fpu_busy_count}]} {
  add wave -noupdate -group FPU_Fleet -color {Medium Orchid} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/fpu_busy_count
  add wave -noupdate -group FPU_Fleet -radix unsigned /mempool_tb/fpu_busy_group
  add wave -noupdate -group FPU_Fleet -radix binary /mempool_tb/fpu_busy
}
if {![catch {examine -radix dec /mempool_tb/spatz_issue_utilization}]} {
  set spatz_lsu_channels [expr $num_cores * [examine -radix dec mempool_pkg::NumMemPortsPerSpatz]]
  if {$spatz_lsu_channels < 1} { set spatz_lsu_channels 1 }
  add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/spatz_issue_utilization
  add wave -noupdate -group Utilization /mempool_tb/spatz_issue_handshake
  add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/spatz_issue_pressure
  add wave -noupdate -group Utilization /mempool_tb/spatz_issue_request
  add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/spatz_rsp_utilization
  add wave -noupdate -group Utilization /mempool_tb/spatz_rsp_handshake
  add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/spatz_rsp_pressure
  add wave -noupdate -group Utilization /mempool_tb/spatz_rsp_request
  add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $spatz_lsu_channels -radix unsigned /mempool_tb/spatz_lsu_utilization
  add wave -noupdate -group Utilization /mempool_tb/spatz_lsu_handshake
  add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $spatz_lsu_channels -radix unsigned /mempool_tb/spatz_lsu_pressure
  add wave -noupdate -group Utilization /mempool_tb/spatz_lsu_request
  add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/spatz_fpu_lsu_utilization
  add wave -noupdate -group Utilization /mempool_tb/spatz_fpu_lsu_handshake
  add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/spatz_fpu_lsu_pressure
  add wave -noupdate -group Utilization /mempool_tb/spatz_fpu_lsu_request
  add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/spatz_fpu_utilization
  add wave -noupdate -group Utilization /mempool_tb/spatz_fpu_handshake
  add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/spatz_fpu_pressure
  add wave -noupdate -group Utilization /mempool_tb/spatz_fpu_request
}
if {[examine -radix dec /snitch_pkg::XPULPIMG]} {
  add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/gen_utilization/dspu_utilization
  add wave -noupdate -group Utilization /mempool_tb/gen_utilization/dspu_handshake
  add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/gen_utilization/mac_utilization
  add wave -noupdate -group Utilization /mempool_tb/gen_utilization/dspu_mac
}
set axi_channels [expr [examine -radix dec mempool_pkg::NumGroups] * [examine -radix dec mempool_pkg::NumAXIMastersPerGroup]]
add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $axi_channels -radix unsigned /mempool_tb/axi_w_utilization
add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $axi_channels -radix unsigned /mempool_tb/axi_r_utilization
if {![catch {examine -radix dec /mempool_tb/noc_req_utilization}]} {
  set noc_req_channels [expr [examine -radix dec mempool_pkg::NumGroups] * [examine -radix dec mempool_pkg::NumTilesPerGroup] * ([examine -radix dec mempool_pkg::NumRemoteReqPortsPerTile] - 1)]
  set noc_resp_channels [expr [examine -radix dec mempool_pkg::NumGroups] * [examine -radix dec mempool_pkg::NumTilesPerGroup] * ([examine -radix dec mempool_pkg::NumRemoteRespPortsPerTile] - 1)]
  if {$noc_req_channels < 1} { set noc_req_channels 1 }
  if {$noc_resp_channels < 1} { set noc_resp_channels 1 }
  set noc_total_channels [expr $noc_req_channels + $noc_resp_channels]
  add wave -noupdate -group NoC_Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $noc_req_channels -radix unsigned /mempool_tb/noc_req_valid_total
  add wave -noupdate -group NoC_Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $noc_req_channels -radix unsigned /mempool_tb/noc_req_utilization
  add wave -noupdate -group NoC_Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $noc_req_channels -radix unsigned /mempool_tb/noc_req_pressure
  add wave -noupdate -group NoC_Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $noc_resp_channels -radix unsigned /mempool_tb/noc_resp_valid_total
  add wave -noupdate -group NoC_Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $noc_resp_channels -radix unsigned /mempool_tb/noc_resp_utilization
  add wave -noupdate -group NoC_Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $noc_resp_channels -radix unsigned /mempool_tb/noc_resp_pressure
  add wave -noupdate -group NoC_Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $noc_total_channels -radix unsigned /mempool_tb/noc_total_utilization
}

# ========================================================================
# Per-group NoC link utilization (valid, ready, handshake per direction)
# Shows traffic on each group's mesh router ports: N/S/E/W × req/resp
# ========================================================================
set NumGroups_noc [examine -radix dec mempool_pkg::NumGroups]
set NumTiles_noc [examine -radix dec mempool_pkg::NumTilesPerGroup]
set NumX_noc ""
set NumY_noc ""
if {[catch {set NumX_noc [examine -radix dec mempool_pkg::NumX]}]} {
  catch {set NumX_noc [examine -radix dec /mempool_pkg::NumX]}
}
if {[catch {set NumY_noc [examine -radix dec mempool_pkg::NumY]}]} {
  catch {set NumY_noc [examine -radix dec /mempool_pkg::NumY]}
}
if {[catch {expr {$NumX_noc + 0}}] || [catch {expr {$NumY_noc + 0}}]} {
  set NumX_noc 1
  set NumY_noc 1
}

for {set g 0} {$g < $NumGroups_noc} {incr g} {
  set gx [expr {$g / $NumX_noc}]
  set gy [expr {$g % $NumY_noc}]
  set base "sim:/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group"
  set grp_label "NoC_Links_G${g}_X${gx}Y${gy}"

  # Wide Req (RDWR) router valid/ready per direction — from the FlooNoC wrapper
  if {![catch {examine ${base}/floo_tcdm_wide_req_valid_out}]} {
    add wave -noupdate -group $grp_label -group WideReq_Valid ${base}/floo_tcdm_wide_req_valid_out
    add wave -noupdate -group $grp_label -group WideReq_Valid ${base}/floo_tcdm_wide_req_valid_in
  }

  # Wide Resp router valid/ready per direction
  if {![catch {examine ${base}/floo_tcdm_resp_valid_out}]} {
    add wave -noupdate -group $grp_label -group Resp_Valid ${base}/floo_tcdm_resp_valid_out
    add wave -noupdate -group $grp_label -group Resp_Valid ${base}/floo_tcdm_resp_valid_in
  }

  # Narrow Req router valid (if narrow channels exist)
  if {![catch {examine ${base}/floo_tcdm_narrow_req_valid_out}]} {
    add wave -noupdate -group $grp_label -group NarrowReq_Valid ${base}/floo_tcdm_narrow_req_valid_out
    add wave -noupdate -group $grp_label -group NarrowReq_Valid ${base}/floo_tcdm_narrow_req_valid_in
  }

  # Master req/resp at MSHR boundary (tile → MSHR → NoC)
  # These are the output ports of the group module. With group_mshr_split=1 the first index is the
  # group NoC LANE {slice[2], k, slice[1:0]} (mempool_pkg::mshr_noc_lane), not the tile.
  add wave -noupdate -group $grp_label -group MSHR_Req ${base}/tcdm_master_req_valid
  add wave -noupdate -group $grp_label -group MSHR_Resp ${base}/tcdm_master_resp_valid

  # Slave req/resp (incoming from NoC → tile banks)
  add wave -noupdate -group $grp_label -group Slave_Req ${base}/tcdm_slave_req_valid
  add wave -noupdate -group $grp_label -group Slave_Resp ${base}/tcdm_slave_resp_valid

  # Resp remapper output (after hash spreading)
  if {![catch {examine ${base}/floo_tcdm_resp_to_router_valid}]} {
    add wave -noupdate -group $grp_label -group Resp_Remapped ${base}/floo_tcdm_resp_to_router_valid
  }
}


# ========================================================================
# Per-group Group-MSHR signals (mempool_group_mshr.sv)
# Entry table + the 4 boundary handshakes + the internal response path that
# carries the message-dependent deadlock (resp_in_*/resp_out_* /
# mshr_noc_resp_ready_o wedging when a stalled core won't accept a response).
# See bottleneck_analysis/2026-06-12_noc_deadlock_fix_report.md.
# Every add is catch-wrapped: configs without a group MSHR, or signals
# optimized away, are skipped rather than aborting the script.
# ========================================================================
# One MSHR core's signals under wave group L, from hierarchical path m. Shared by the legacy
# single group MSHR and by each slice of the split MSHR (mempool_group_mshr_slice.sv).
proc add_mshr_core_wave {m L} {

    # --- Occupancy / utilization ---
    # mshr_q_valid counts response-cache ways too, so use mshr_inuse_* for real MSHR
    # utilization; mshr_held_* is the subset whose NoC fetch is still withheld by
    # hold-the-fetch (0 unless group_mshr_hold_window > 0).
    catch {add wave -noupdate -group $L -group Util -radix unsigned ${m}/mshr_inuse_cnt_dbg}
    catch {add wave -noupdate -group $L -group Util -radix unsigned ${m}/mshr_cached_cnt_dbg}
    catch {add wave -noupdate -group $L -group Util -radix unsigned ${m}/mshr_held_cnt_dbg}
    catch {add wave -noupdate -group $L -group Util -radix unsigned ${m}/mshr_valid_cnt_dbg}
    catch {add wave -noupdate -group $L -group Util ${m}/mshr_inuse_dbg}
    catch {add wave -noupdate -group $L -group Util ${m}/mshr_cached_dbg}
    catch {add wave -noupdate -group $L -group Util ${m}/mshr_held_dbg}
    # Hold-the-fetch release reason: which entry issued its withheld fetch this cycle,
    # and why (window expired vs early-release subscriber target met). Counters are
    # free-running from reset -- take a cursor-to-cursor delta to scope a region.
    catch {add wave -noupdate -group $L -group HoldRelease ${m}/mshr_issue_timeout_dbg}
    catch {add wave -noupdate -group $L -group HoldRelease ${m}/mshr_issue_subs_dbg}
    catch {add wave -noupdate -group $L -group HoldRelease -radix unsigned ${m}/mshr_issue_timeout_cnt_dbg}
    catch {add wave -noupdate -group $L -group HoldRelease -radix unsigned ${m}/mshr_issue_subs_cnt_dbg}
    # Bank-full alloc bypass: a mergeable load wanted an MSHR entry but its bank was
    # full, so it bypassed to the NoC without one (per-request vector + running count).
    catch {add wave -noupdate -group $L -group BankFullBypass ${m}/req_bankfull_bypass_dbg}
    catch {add wave -noupdate -group $L -group BankFullBypass -radix unsigned ${m}/req_bankfull_bypass_cnt_dbg}
    # Cache lifecycle counters (present only when group_mshr_enable_stats=1). A CACHED line
    # leaves the cache via evict (alloc reclaim), amo_inval (AMO), or self_inval (idea 1
    # self-invalidate at the served target). self_inval is the NEW drain path -- without it the
    # fill vs evict accounting does not balance and hit_rate=hit/(hit+evict) reads high. The
    # *_cycle signal pulses every cycle (always live); the bare accumulators advance only while
    # csr_trace is active (benchmark-gated). served_cnt (per entry) is under Entries/mshr_q.
    catch {add wave -noupdate -group $L -group CacheStats -radix unsigned ${m}/stat_cache_self_inval_cycle}
    catch {add wave -noupdate -group $L -group CacheStats -radix unsigned ${m}/stat_cache_self_inval}
    catch {add wave -noupdate -group $L -group CacheStats -radix unsigned ${m}/stat_cache_evict}
    catch {add wave -noupdate -group $L -group CacheStats -radix unsigned ${m}/stat_cache_amo_inval}
    catch {add wave -noupdate -group $L -group CacheStats -radix unsigned ${m}/stat_cache_fill}
    catch {add wave -noupdate -group $L -group CacheStats -radix unsigned ${m}/stat_cache_hit}

    # --- Entry table (state / base_addr / resp_buf_cnt / sub_reqs / beat_pending ...) ---
    catch {add wave -noupdate -group $L -group Entries ${m}/mshr_q_valid}
    catch {add wave -noupdate -group $L -group Entries ${m}/mshr_q}
    catch {add wave -noupdate -group $L -group Entries ${m}/mshr_resp_inflight}

    # --- Overflow pool: MshrOverflowNum extra UNBANKED entries (group_mshr_overflow_num, def 1) ---
    # Deliberately a SECOND array, not a wider banked table. BankPublish asserts
    # idx_width(MshrNum) == BankIdW + VictimPtrW (6 == 4+2 at 64 entries / 4 per bank), so one more
    # banked entry fails elaboration; and mshr_id_t is idx_width(MshrNum) wide, so a pool tag cast
    # through it would truncate onto banked entry 0. Pool tags run MshrNum+1 .. MshrNum+K.
    #
    # Because the pool is a separate array, NO scan widens automatically: every pass that walks the
    # banked table needs its own pool arm, and a missing arm reads as "allocated but never drained"
    # -- a clean compile and a hang. These waves are how the two failure classes are told apart:
    # Pool_Grant says a decision landed, Pool_Entry says the state actually moved. In-flight with no
    # state change is a dropped write (clock gate); state with no in-flight is a missed pool arm.
    # The pool generate is elab'd away at MshrOverflowNum=0, so gate the block on a signal in it.
    if {![catch {examine ${m}/gen_pool_reg/pool_ctl_en}]} {
      # pool_q_valid counts ONLY pool entries -- unlike mshr_q_valid, which counts response-cache
      # ways too, so the two are not comparable as occupancies.
      catch {add wave -noupdate -group $L -group Pool_Entry ${m}/pool_q_valid}
      catch {add wave -noupdate -group $L -group Pool_Entry ${m}/pool_q}
      catch {add wave -noupdate -group $L -group Pool_Entry ${m}/pool_d_valid}
      catch {add wave -noupdate -group $L -group Pool_Entry ${m}/pool_d}
      # Clock-gate enables, the same three groups the banked registers use. A gate narrower than
      # the pool's own next-state cone drops the write and leaves the previous occupant's
      # self-consistent snapshot -- which every per-entry assertion still passes.
      catch {add wave -noupdate -group $L -group Pool_Gate ${m}/gen_pool_reg/pool_ctl_en}
      catch {add wave -noupdate -group $L -group Pool_Gate ${m}/gen_pool_reg/pool_id_en}
      catch {add wave -noupdate -group $L -group Pool_Gate ${m}/gen_pool_reg/pool_rb_en}
      # Allocation / merge grant, plus the free-entry pointer (one pool entry, so pool_free_id is
      # always 0 -- it exists so the pool arbiter keeps the banked one's shape).
      catch {add wave -noupdate -group $L -group Pool_Grant ${m}/pool_alloc_inflight}
      catch {add wave -noupdate -group $L -group Pool_Grant ${m}/pool_merge_inflight}
      catch {add wave -noupdate -group $L -group Pool_Grant ${m}/pool_st_merge_drain}
      catch {add wave -noupdate -group $L -group Pool_Grant ${m}/pool_free_valid}
      catch {add wave -noupdate -group $L -group Pool_Grant ${m}/pool_has_free}
      catch {add wave -noupdate -group $L -group Pool_Grant -radix unsigned ${m}/pool_free_id}
      catch {add wave -noupdate -group $L -group Pool_Grant ${m}/pool_free_oh}
      catch {add wave -noupdate -group $L -group Pool_Grant ${m}/apb_v}
      catch {add wave -noupdate -group $L -group Pool_Grant ${m}/apb_q_v}
      catch {add wave -noupdate -group $L -group Pool_Grant -radix unsigned ${m}/apb_q_way}
      catch {add wave -noupdate -group $L -group Pool_Grant ${m}/apb_q_len}
      catch {add wave -noupdate -group $L -group Pool_Grant ${m}/mpb_v}
      catch {add wave -noupdate -group $L -group Pool_Grant ${m}/mpb_q_v}
      catch {add wave -noupdate -group $L -group Pool_Grant -radix unsigned ${m}/mpb_q_way}
      # Per-lane outcome for this cycle, indexed [tile][port]: hit an existing pool entry, won a
      # pool entry, and which one. req_hit_pool feeds req_hit_mshr, which is what keeps a pooled
      # request from ALSO being an allocation candidate -- check it against Pool_Lane alloc_found.
      catch {add wave -noupdate -group $L -group Pool_Lane ${m}/req_hit_pool}
      catch {add wave -noupdate -group $L -group Pool_Lane ${m}/req_alloc_found_pool}
      catch {add wave -noupdate -group $L -group Pool_Lane -radix unsigned ${m}/req_alloc_found_pool_id}
    }

    # --- Bank allocation cut (the pipeline-cut invariant suite) ---
    # The arbiter's own view of which ways are taken, one cycle behind the grant (agb_q_* is just
    # the registered agb_*). cut_alloc_target_free fires when a grant lands on a way that is
    # already valid and not CACHED -- i.e. the free-way lookup and free_way_valid disagree. That is
    # the assertion a pool run currently dies on ~400 cycles into the benchmark, so park these
    # beside Pool_Grant: at the failure, find the cycle where agb_q_v[bank] is high while
    # free_way_valid[way] is also high, and read agb_q_way to get the way that was taken twice.
    catch {add wave -noupdate -group $L -group Alloc_Cut ${m}/free_way_valid}
    catch {add wave -noupdate -group $L -group Alloc_Cut ${m}/alloc_inflight}
    catch {add wave -noupdate -group $L -group Alloc_Cut ${m}/merge_inflight}
    catch {add wave -noupdate -group $L -group Alloc_Cut ${m}/agb_v}
    catch {add wave -noupdate -group $L -group Alloc_Cut ${m}/agb_q_v}
    catch {add wave -noupdate -group $L -group Alloc_Cut -radix unsigned ${m}/agb_q_way}
    catch {add wave -noupdate -group $L -group Alloc_Cut ${m}/bank_has_free}
    catch {add wave -noupdate -group $L -group Alloc_Cut -radix unsigned ${m}/bank_free_id}

    # --- Boundary 1: tiles -> MSHR (request ingress) ---
    catch {add wave -noupdate -group $L -group ReqIn  ${m}/group_mshr_req_valid_i}
    catch {add wave -noupdate -group $L -group ReqIn  ${m}/group_mshr_req_ready_o}
    catch {add wave -noupdate -group $L -group ReqIn  ${m}/group_mshr_req_i}
    catch {add wave -noupdate -group $L -group ReqIn  ${m}/req_merge_valid}
    catch {add wave -noupdate -group $L -group ReqIn  ${m}/req_alloc_found}

    # --- Boundary 2: MSHR -> NoC (request egress) ---
    catch {add wave -noupdate -group $L -group ReqOutNoC ${m}/mshr_noc_req_valid_o}
    catch {add wave -noupdate -group $L -group ReqOutNoC ${m}/mshr_noc_req_ready_i}
    catch {add wave -noupdate -group $L -group ReqOutNoC ${m}/mshr_noc_req_o}

    # --- Boundary 3: NoC -> MSHR (response ingress) — DEADLOCK SOURCE ---
    # mshr_noc_resp_ready_o wedges low when the matched entry's resp_buf is full
    # or (bypass) the drain output is back-pressured by a stalled core.
    catch {add wave -noupdate -group $L -group RespInNoC ${m}/mshr_noc_resp_valid_i}
    catch {add wave -noupdate -group $L -group RespInNoC ${m}/mshr_noc_resp_ready_o}
    catch {add wave -noupdate -group $L -group RespInNoC ${m}/mshr_noc_resp_i}

    # --- Boundary 4: MSHR -> tiles (response egress / multicast drain) ---
    catch {add wave -noupdate -group $L -group RespOut ${m}/group_mshr_resp_valid_o}
    catch {add wave -noupdate -group $L -group RespOut ${m}/group_mshr_resp_ready_i}
    catch {add wave -noupdate -group $L -group RespOut ${m}/group_mshr_resp_o}

    # --- Internal response path (post-spill) — watch these for the wedge ---
    catch {add wave -noupdate -group $L -group RespPath ${m}/resp_in_valid}
    catch {add wave -noupdate -group $L -group RespPath ${m}/resp_in_ready}
    catch {add wave -noupdate -group $L -group RespPath ${m}/resp_in}
    catch {add wave -noupdate -group $L -group RespPath ${m}/resp_out_valid}
    catch {add wave -noupdate -group $L -group RespPath ${m}/resp_out_ready}
    catch {add wave -noupdate -group $L -group RespPath ${m}/resp_out}
    catch {add wave -noupdate -group $L -group RespPath ${m}/mshr_resp_slots}
    catch {add wave -noupdate -group $L -group RespPath ${m}/resp_capture_fire}

    # --- Response classification (bypass vs MSHR-managed, drain selection) ---
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_is_mshr}
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_mshr_id}
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_from_mshr}
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_from_bypass}
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_mshr_id_dbg}
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_sel_valid}
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_sel_mshr_id}
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_sel_subreq_idx}
}

# Per group: the legacy instance (gen_group_mshr/i_group_mshr), or -- with group_mshr_split=1 --
# the eight slice cores gen_group_mshr_split/gen_slice[m]/i_slice/i_core, labelled R0..R3 (row
# slices, tiles 4k..4k+3) and C0..C3 (column slices, tiles k,k+4,k+8,k+12), plus each slice's
# 4-lane NoC face (the request fold / response steer) under Slice.
proc add_group_mshr_wave {g NumX NumY} {
    set gx [expr {$g / $NumX}]
    set gy [expr {$g % $NumY}]
    set grp "sim:/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group"
    set legacy "${grp}/gen_group_mshr/i_group_mshr"
    if {![catch {examine ${legacy}/mshr_q_valid}]} {
        add_mshr_core_wave $legacy "MSHR_G${g}_X${gx}Y${gy}"
        return
    }
    # Group-level split logic: the class steer per tile port (to_col = 1 -> column slice), the
    # row/column response arbiters, and the CSR that decides which family serves singles.
    set S "MSHR_G${g}_X${gx}Y${gy}_Steer"
    catch {add wave -noupdate -group $S ${grp}/mshr_cfg.steer_single_row}
    catch {add wave -noupdate -group $S ${grp}/mshr_cfg.enable}
    catch {add wave -noupdate -group $S ${grp}/gen_group_mshr_split/sl_busy}
    catch {add wave -noupdate -group $S ${grp}/gen_group_mshr_split/cfg_bypass_single}
    catch {add wave -noupdate -group $S ${grp}/gen_group_mshr_split/cfg_bypass_burst}
    catch {add wave -noupdate -group $S -group ToSlice ${grp}/gen_group_mshr_split/sl_req_valid}
    catch {add wave -noupdate -group $S -group ToSlice ${grp}/gen_group_mshr_split/sl_req_ready}
    catch {add wave -noupdate -group $S -group FromSlice ${grp}/gen_group_mshr_split/sl_resp_valid}
    catch {add wave -noupdate -group $S -group FromSlice ${grp}/gen_group_mshr_split/sl_resp_ready}
    catch {add wave -noupdate -group $S -group NoCFace ${grp}/gen_group_mshr_split/sl_noc_req_valid}
    catch {add wave -noupdate -group $S -group NoCFace ${grp}/gen_group_mshr_split/sl_noc_resp_valid}
    for {set t 0} {$t < 16} {incr t} {
        set st "${grp}/gen_group_mshr_split/gen_steer_t\[${t}\]"
        catch {add wave -noupdate -group $S -group Tile${t} ${st}/gen_steer_r\[1\]/is_burst}
        catch {add wave -noupdate -group $S -group Tile${t} ${st}/gen_steer_r\[1\]/to_col}
        catch {add wave -noupdate -group $S -group Tile${t} ${st}/gen_steer_r\[2\]/is_burst}
        catch {add wave -noupdate -group $S -group Tile${t} ${st}/gen_steer_r\[2\]/to_col}
    }
    for {set m 0} {$m < 8} {incr m} {
        set sl "${grp}/gen_group_mshr_split/gen_slice\[${m}\]/i_slice"
        if {[catch {examine ${sl}/i_core/mshr_q_valid}]} { continue }
        set fam [expr {$m < 4 ? "R" : "C"}]
        set L "MSHR_G${g}_X${gx}Y${gy}_${fam}[expr {$m % 4}]"
        add_mshr_core_wave "${sl}/i_core" $L
        catch {add wave -noupdate -group $L -group Slice ${sl}/noc_req_valid_o}
        catch {add wave -noupdate -group $L -group Slice ${sl}/noc_req_ready_i}
        catch {add wave -noupdate -group $L -group Slice ${sl}/noc_req_o}
        catch {add wave -noupdate -group $L -group Slice ${sl}/noc_resp_valid_i}
        catch {add wave -noupdate -group $L -group Slice ${sl}/noc_resp_ready_o}
        catch {add wave -noupdate -group $L -group Slice ${sl}/noc_resp_i}
        catch {add wave -noupdate -group $L -group Slice ${sl}/tile_req_valid_i}
        catch {add wave -noupdate -group $L -group Slice ${sl}/tile_req_ready_o}
        catch {add wave -noupdate -group $L -group Slice ${sl}/tile_resp_valid_o}
        catch {add wave -noupdate -group $L -group Slice ${sl}/tile_resp_ready_i}
    }
}

for {set g 0} {$g < $NumGroups_noc} {incr g} {
    add_group_mshr_wave $g $NumX_noc $NumY_noc
}

# Spatz vector-core signals for one core (group g, tile t, core c). Answers: what vector
# instruction is executing, why the core is stalled, and which lanes/FPUs do useful work each
# cycle. Every add is catch-wrapped so non-Spatz configs / absent submodules skip cleanly.
proc add_spatz_core_wave {g t c NumX NumY} {
    set gx [expr {$g / $NumX}]
    set gy [expr {$g % $NumY}]
    set cc "sim:/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core"
    set s "${cc}/i_spatz"
    # Skip if this core has no Spatz instance (non-Spatz config).
    if {[catch {examine ${s}/i_controller/spatz_req_valid_o}]} { return }
    set L "SPATZ_G${g}_T${t}_C${c}"

    # --- Trace cycle counter (FIRST, so it reads as the time base for everything below) ---
    # sp_cycle is the tracer's own free-running counter (spatz_mempool_cc.sv: reset to 0, +1 per
    # posedge clk_i). It is the EXACT `cyc` field printed in trace_spatz_{insn,cyc,fplsu}_hart_*.log
    # (and identical to the Snitch tracer's `cycle` in trace_hart_*.dasm), so a cycle number read
    # here jumps straight to the matching trace line. Waveform time relation: ns = 2*cyc + 10
    # (ClockPeriod 2ns, reset released at 10ns). Sim-only (translate_off), so it is catch-guarded.
    catch {add wave -noupdate -group $L -radix unsigned ${cc}/sp_cycle}

    # --- Issue / decode: which vector instruction is executing, and the in-flight id set ---
    catch {add wave -noupdate -group $L -group Issue ${s}/i_controller/spatz_req_valid_o}
    catch {add wave -noupdate -group $L -group Issue ${s}/i_controller/spatz_req_o}
    catch {add wave -noupdate -group $L -group Issue ${s}/i_controller/running_insn_q}
    catch {add wave -noupdate -group $L -group Issue ${s}/i_controller/running_insn_full}
    # --- Stall + reason (issue stage + dependency scoreboard) ---
    catch {add wave -noupdate -group $L -group Stall ${s}/i_controller/stall}
    catch {add wave -noupdate -group $L -group Stall ${s}/i_controller/vfu_stall}
    catch {add wave -noupdate -group $L -group Stall ${s}/i_controller/vlsu_stall}
    catch {add wave -noupdate -group $L -group Stall ${s}/i_controller/vsldu_stall}
    catch {add wave -noupdate -group $L -group Stall ${s}/i_controller/sb_port_has_deps_dbg}
    catch {add wave -noupdate -group $L -group Stall ${s}/i_controller/sb_port_enable_dbg}
    # FP sequencer (scalar FP path) stall reasons.
    catch {add wave -noupdate -group $L -group Stall ${s}/gen_fpu_sequencer/i_fpu_sequencer/stall}
    catch {add wave -noupdate -group $L -group Stall ${s}/gen_fpu_sequencer/i_fpu_sequencer/lsu_stall}
    catch {add wave -noupdate -group $L -group Stall ${s}/gen_fpu_sequencer/i_fpu_sequencer/move_stall}
    catch {add wave -noupdate -group $L -group Stall ${s}/gen_fpu_sequencer/i_fpu_sequencer/operands_available}
    # --- VFU: per-lane IPU + per-FPU useful work (int_ipu_result_valid / fpu_result_valid carry
    # ELENB bits per lane; a lane worked this cycle if any of its bits are set). ---
    catch {add wave -noupdate -group $L -group VFU ${s}/i_vfu/state_q}
    catch {add wave -noupdate -group $L -group VFU ${s}/i_vfu/int_ipu_busy}
    catch {add wave -noupdate -group $L -group VFU ${s}/i_vfu/int_ipu_result_valid}
    catch {add wave -noupdate -group $L -group VFU ${s}/i_vfu/fpu_result_valid}
    catch {add wave -noupdate -group $L -group VFU ${s}/i_vfu/is_ipu_busy}
    catch {add wave -noupdate -group $L -group VFU ${s}/i_vfu/is_fpu_busy}
    catch {add wave -noupdate -group $L -group VFU ${s}/i_vfu/vfu_rsp_valid_o}
    # --- VLSU: memory-beat activity + FSM state ---
    catch {add wave -noupdate -group $L -group VLSU ${s}/i_vlsu/state_q}
    catch {add wave -noupdate -group $L -group VLSU ${s}/i_vlsu/spatz_mem_req_valid_o}
    catch {add wave -noupdate -group $L -group VLSU ${s}/i_vlsu/spatz_mem_req_ready_i}
    catch {add wave -noupdate -group $L -group VLSU ${s}/i_vlsu/spatz_mem_rsp_valid_i}
    catch {add wave -noupdate -group $L -group VLSU ${s}/i_vlsu/commit_operation_valid}
    catch {add wave -noupdate -group $L -group VLSU ${s}/i_vlsu/vlsu_rsp_valid_o}
}

# Default: wave core 0 of group 0 (tile 0). Waving all 256 cores is impractical -- call the proc
# for more cores of interest, e.g. `add_spatz_core_wave 0 1 0 $NumX_noc $NumY_noc`.
add_spatz_core_wave 0 0 0 $NumX_noc $NumY_noc


# Add a vector of the core's wfi signal to quickly see which cores are active
add wave /mempool_tb/wfi

# Add the spm bank util of one tile
set NumX ""
if {[catch {set NumX [examine -radix dec mempool_pkg::NumX]}]} {
  catch {set NumX [examine -radix dec /mempool_pkg::NumX]}
}
set NumY ""
if {[catch {set NumY [examine -radix dec mempool_pkg::NumY]}]} {
  catch {set NumY [examine -radix dec /mempool_pkg::NumY]}
}
if {[catch {expr {$NumX + 0}}] || [catch {expr {$NumY + 0}}]} {
  set NumX 1
  set NumY 1
}
for {set group 0} {$group < [examine -radix dec /mempool_pkg::NumGroups]} {incr group} {
    for {set tile 0} {$tile < [examine -radix dec /mempool_pkg::NumTilesPerGroup]} {incr tile} {
        add wave -Group super_bank_req_valid -position insertpoint sim:/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${tile}\]/i_tile/superbank_req_valid
    }
}

# Add all cores from group 0 tile 0
for {set core 0}  {$core < [examine -radix dec mempool_pkg::NumCoresPerTile]} {incr core} {
    for {set tile 0} {$tile < 2} {incr tile} {
        if {![catch {examine -radix dec /mempool_tb/spatz_issue_utilization}]} {
            do ../scripts/questa/wave_spatz_core.tcl 0 $tile $core $NumY
        } else {
            do ../scripts/questa/wave_core.tcl 0 $tile $core $NumY
        }
    }
}

# Add specific cores from different tiles (guarded for small configs)
set NumGroups [examine -radix dec mempool_pkg::NumGroups]
set NumTilesPerGroup [examine -radix dec mempool_pkg::NumTilesPerGroup]
set NumCoresPerTile [examine -radix dec mempool_pkg::NumCoresPerTile]
set HasSpatz [expr {![catch {examine -radix dec /mempool_tb/spatz_issue_utilization}]}]

proc add_core_wave_by_global_id {global_core NumGroups NumTilesPerGroup NumCoresPerTile NumY HasSpatz} {
    set cores_per_group [expr {$NumTilesPerGroup * $NumCoresPerTile}]
    if {$cores_per_group <= 0} {
        return
    }

    set group [expr {$global_core / $cores_per_group}]
    set core_in_group [expr {$global_core % $cores_per_group}]
    set tile [expr {$core_in_group / $NumCoresPerTile}]
    set core [expr {$core_in_group % $NumCoresPerTile}]

    if {$group < 0 || $group >= $NumGroups} {
        return
    }
    if {$tile < 0 || $tile >= $NumTilesPerGroup} {
        return
    }
    if {$core < 0 || $core >= $NumCoresPerTile} {
        return
    }

    if {$HasSpatz} {
        do ../scripts/questa/wave_spatz_core.tcl $group $tile $core $NumY
    } else {
        do ../scripts/questa/wave_core.tcl $group $tile $core $NumY
    }
}

if {$NumGroups > 1} {
    if {$HasSpatz} {
        do ../scripts/questa/wave_spatz_core.tcl 1 0 0 $NumY
    } else {
        do ../scripts/questa/wave_core.tcl 1 0 0 $NumY
    }
}
if {$NumGroups > 1 && $NumTilesPerGroup > 1 && $NumCoresPerTile > 1} {
    if {$HasSpatz} {
        do ../scripts/questa/wave_spatz_core.tcl 1 1 1 $NumY
    } else {
        do ../scripts/questa/wave_core.tcl 1 1 1 $NumY
    }
}
if {$NumGroups > 0 && $NumTilesPerGroup > 0 && $NumCoresPerTile > 0} {
    if {$HasSpatz} {
        do ../scripts/questa/wave_spatz_core.tcl [expr {$NumGroups-1}] [expr {$NumTilesPerGroup-1}] [expr {$NumCoresPerTile-1}] $NumY
    } else {
        do ../scripts/questa/wave_core.tcl [expr {$NumGroups-1}] [expr {$NumTilesPerGroup-1}] [expr {$NumCoresPerTile-1}] $NumY
    }
}

# Add selected cores by global core ID for targeted debug.
# sp-fmatmul-opt-burst-merge stuck cores (build_2), wedge order; first 6 = Group 12
# hard-frozen deadlock cluster (tiles 9-14). See bottleneck_analysis/2026-06-11_sp_fmatmul_stuck_cores.md
foreach global_core {0 8 1 9 2 10 3 11 4 12 5 13 6 14 7 15 \
                      48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 \
                      192 193 194 195 196 197 198 199 200 201 202 203 204 205 206 207 \
                      128 129 130 131 132 133 134 135 136 137 138 139 140 141 142 143 \
                      } {
    add_core_wave_by_global_id $global_core $NumGroups $NumTilesPerGroup $NumCoresPerTile $NumY $HasSpatz
}

# Add groups
set DmaBurstLen [examine -radix dec mempool_pkg::DmaBurstLen]
set Interleave [examine -radix dec mempool_pkg::Interleave]

for {set group 0} {$group < [examine -radix dec /mempool_pkg::NumGroups]} {incr group} {
    # Add Interface
    add wave -group group_[$group] -group X[[expr ${group}/${NumX}]]Y[[expr ${group}%${NumY}]]_Intf /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/*
    # Addr Map
    add wave -group group_[$group] -group addr_map /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/addr_map
    # Add Tiles
    for {set tile 0} {$tile < [examine -radix dec /mempool_pkg::NumTilesPerGroup]} {incr tile} {
        do ../scripts/questa/wave_tile.tcl $group $tile $NumY
    }
    # Local TCDM
    add wave -group group_[$group] -group interconnect_local /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/tcdm_master_req*
    add wave -group group_[$group] -group interconnect_local /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/tcdm_master_resp*
    add wave -group group_[$group] -group interconnect_local /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/tcdm_slave_req*
    add wave -group group_[$group] -group interconnect_local /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/tcdm_slave_resp*
    # TCDM Router - Request Ports (wide + narrow)
    for {set tile 0} {$tile < [examine -radix dec /mempool_pkg::NumTilesPerGroup]} {incr tile} {
        # Wide Request Ports
        for {set port 1} {$port < [examine -radix dec /mempool_pkg::NumWideRemoteReqPortsPerTile]} {incr port} {
            add wave -group group_[$group] -group floo_tcdm_router_req \
            /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/gen_router_router_i[$tile]/gen_router_wide_req_router_j[$port]/gen_2dmesh/i_floo_tcdm_wide_req_router/*
        }
        # Narrow Request Ports (optional, only if enabled)
        for {set port 1} {$port < [examine -radix dec /mempool_pkg::NumNarrowRemoteReqPortsPerTile]} {incr port} {
            add wave -group group_[$group] -group floo_tcdm_router_req \
            /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/gen_router_router_i[$tile]/gen_router_narrow_req_router_j[$port]/gen_2dmesh/i_floo_tcdm_narrow_req_router/*
        }
    }
    # TCDM Router - Response Ports (only wide)
    for {set tile 0} {$tile < [examine -radix dec /mempool_pkg::NumTilesPerGroup]} {incr tile} {
        for {set port 1} {$port < [examine -radix dec /mempool_pkg::NumRemoteRespPortsPerTile]} {incr port} {
            add wave -group group_[$group] -group floo_tcdm_router_resp \
            /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/gen_router_router_i[$tile]/gen_router_wide_resp_router_j[$port]/gen_2dmesh/i_floo_tcdm_wide_resp_router/*
        }
    }
    # Splitter & Interleaver
    if {$DmaBurstLen > $Interleave} {
      add wave -group group_[$group] -group axi_splitter /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/gen_axi_splitter/i_axi_burst_splitter/*
    }
    add wave -group group_[$group] -group axi_interleaver /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_axi_L2_interleaver/*
    # AXI Router
    add wave -group group_[$group] -group floo_axi_chimney /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_floo_narrow_wide_chimney/*
    add wave -group group_[$group] -group floo_axi_router /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_floo_narrow_wide_router/*
}

# Add cluster
do ../scripts/questa/wave_cluster.tcl

# Add System
add wave -group system -group soc_xbar /mempool_tb/dut/i_soc_xbar/*
add wave -group system -group axi2mem_bootrom /mempool_tb/dut/i_axi2mem_bootrom/*
set NumDrams ""
if {![catch {examine -radix dec mempool_pkg::NumDrams} NumDrams]} {
  # using mempool_pkg::NumDrams
} elseif {![catch {examine -radix dec /mempool_pkg::NumDrams} NumDrams]} {
  # using /mempool_pkg::NumDrams
}
if {$NumDrams ne ""} {
  for {set dram 0} {$dram < $NumDrams} {incr dram} {
      add wave -group system -group dram_[$dram] /mempool_tb/dut/gen_drams[$dram]/i_axi_dram_sim/*
  }
} else {
  for {set bank 0} {$bank < [examine -radix dec /mempool_pkg::NumL2Banks]} {incr bank} {
      add wave -group system -group L2_banks -group axi2mem_[$bank] /mempool_tb/dut/gen_l2_adapters[$bank]/i_axi2mem/*
      add wave -group system -group L2_banks -group bank_[$bank] /mempool_tb/dut/gen_l2_banks[$bank]/l2_mem/*
  }
}

# Add AXI
add wave -noupdate -group cluster mempool_tb/dut/axi_mst_req
add wave -noupdate -group cluster mempool_tb/dut/axi_mst_resp

# Add CSR
add wave -group system -group CSR /mempool_tb/dut/i_ctrl_registers/*

# Add DMA
add wave -group DMA -group dma_top /mempool_tb/dut/i_mempool_dma/*
add wave -group DMA -group frontend_reg /mempool_tb/dut/i_mempool_dma/i_mempool_dma_frontend_reg_top/*
add wave -group DMA -group midend_cluster /mempool_tb/dut/i_idma_distributed_midend/NoMstPorts
add wave -group DMA -group midend_cluster /mempool_tb/dut/i_idma_distributed_midend/DmaRegionWidth
add wave -group DMA -group midend_cluster /mempool_tb/dut/i_idma_distributed_midend/DmaRegionStart
add wave -group DMA -group midend_cluster /mempool_tb/dut/i_idma_distributed_midend/DmaRegionEnd
add wave -group DMA -group midend_cluster /mempool_tb/dut/i_idma_distributed_midend/DmaRegionAddressBits
add wave -group DMA -group midend_cluster /mempool_tb/dut/i_idma_distributed_midend/FullRegionAddressBits
add wave -group DMA -group midend_cluster /mempool_tb/dut/i_idma_distributed_midend/*
add wave -group DMA -group midend_cluster_split /mempool_tb/dut/i_idma_split_midend/*

for {set group 0} {$group < [examine -radix dec /mempool_pkg::NumGroups]} {incr group} {
    add wave -group DMA -group midend_group_${group} /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/i_idma_distributed_midend/NoMstPorts
    add wave -group DMA -group midend_group_${group} /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/i_idma_distributed_midend/DmaRegionWidth
    add wave -group DMA -group midend_group_${group} /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/i_idma_distributed_midend/DmaRegionStart
    add wave -group DMA -group midend_group_${group} /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/i_idma_distributed_midend/DmaRegionEnd
    add wave -group DMA -group midend_group_${group} /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/i_idma_distributed_midend/DmaRegionAddressBits
    add wave -group DMA -group midend_group_${group} /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/i_idma_distributed_midend/FullRegionAddressBits
    add wave -group DMA -group midend_group_${group} /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/i_idma_distributed_midend/*
    for {set dma 0} {$dma < [examine -radix dec /mempool_pkg::NumDmasPerGroup]} {incr dma} {
      add wave -group DMA -Group backend_group${group}_be${dma} /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_dmas[$dma]/i_axi_dma_backend/*
    }
    add wave -group DMA -group tcdm_dma_group_${group} /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/tcdm_dma_req*
    add wave -group DMA -group tcdm_dma_group_${group} /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/tcdm_dma_resp*
}

do ../scripts/questa/wave_cache.tcl 0 0 0 $NumY

# Core Memory Scoreboard VIP — aggregate counters and live status per (g,t,c,p).
# Add cms_tbl entries manually for specific ports of interest (large array).
if {![catch {examine /mempool_tb/u_cms/cms_cycle}]} {
  add wave -noupdate -group "VIP CMS" /mempool_tb/u_cms/cms_cycle
  add wave -noupdate -group "VIP CMS" /mempool_tb/u_cms/cms_benchmark_active
  add wave -noupdate -group "VIP CMS" /mempool_tb/u_cms/cms_n_req
  add wave -noupdate -group "VIP CMS" /mempool_tb/u_cms/cms_n_resp_done
  add wave -noupdate -group "VIP CMS" /mempool_tb/u_cms/cms_n_inflight
  add wave -noupdate -group "VIP CMS" /mempool_tb/u_cms/cms_n_inflight_hw
  add wave -noupdate -group "VIP CMS" /mempool_tb/u_cms/cms_n_orphan
  add wave -noupdate -group "VIP CMS" /mempool_tb/u_cms/cms_n_dup_alloc
  add wave -noupdate -group "VIP CMS" /mempool_tb/u_cms/cms_lat_max
}
