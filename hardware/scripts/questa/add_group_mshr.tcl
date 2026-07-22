# add_group_mshr.tcl
# Append the group-MSHR debug signals to the CURRENT Wave window (no full reload).
# Run from the QuestaSim Tcl console (cwd = your build dir, e.g. hardware/build_2):
#     do ../scripts/questa/add_group_mshr.tcl            ;# all groups
#     do ../scripts/questa/add_group_mshr.tcl 12         ;# only group 12
# Safe to run on an already-populated wave: `add wave` appends; every add is
# catch-wrapped so missing/optimized signals are skipped, not fatal.
# Self-contained: does not depend on wave.tcl having been sourced.
# See bottleneck_analysis/2026-06-12_noc_deadlock_fix_report.md.

set NumGroups [examine -radix dec mempool_pkg::NumGroups]
set NumX ""
set NumY ""
if {[catch {set NumX [examine -radix dec mempool_pkg::NumX]}]} {
  catch {set NumX [examine -radix dec /mempool_pkg::NumX]}
}
if {[catch {set NumY [examine -radix dec mempool_pkg::NumY]}]} {
  catch {set NumY [examine -radix dec /mempool_pkg::NumY]}
}
if {[catch {expr {$NumX + 0}}] || [catch {expr {$NumY + 0}}]} { set NumX 1; set NumY 1 }

proc add_group_mshr_wave {g NumX NumY} {
    set gx [expr {$g / $NumX}]
    set gy [expr {$g % $NumY}]
    set m "sim:/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/gen_group_mshr/i_group_mshr"
    if {[catch {examine ${m}/mshr_q_valid}]} { return 0 }
    set L "MSHR_G${g}_X${gx}Y${gy}"

    # Occupancy / utilization: mshr_q_valid counts response-cache ways too, so use
    # mshr_inuse_* for real MSHR utilization. mshr_held_* is the subset whose fetch is
    # still withheld by hold-the-fetch (0 unless group_mshr_hold_window > 0).
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

    # Entry table (state / base_addr / resp_buf_cnt / sub_reqs / beat_pending ...)
    catch {add wave -noupdate -group $L -group Entries ${m}/mshr_q_valid}
    catch {add wave -noupdate -group $L -group Entries ${m}/mshr_q}
    catch {add wave -noupdate -group $L -group Entries ${m}/mshr_resp_inflight}

    # Boundary 1: tiles -> MSHR (request ingress)
    catch {add wave -noupdate -group $L -group ReqIn  ${m}/group_mshr_req_valid_i}
    catch {add wave -noupdate -group $L -group ReqIn  ${m}/group_mshr_req_ready_o}
    catch {add wave -noupdate -group $L -group ReqIn  ${m}/group_mshr_req_i}
    catch {add wave -noupdate -group $L -group ReqIn  ${m}/req_merge_valid}
    catch {add wave -noupdate -group $L -group ReqIn  ${m}/req_alloc_found}

    # Boundary 2: MSHR -> NoC (request egress)
    catch {add wave -noupdate -group $L -group ReqOutNoC ${m}/mshr_noc_req_valid_o}
    catch {add wave -noupdate -group $L -group ReqOutNoC ${m}/mshr_noc_req_ready_i}
    catch {add wave -noupdate -group $L -group ReqOutNoC ${m}/mshr_noc_req_o}

    # Boundary 3: NoC -> MSHR (response ingress) — DEADLOCK SOURCE
    catch {add wave -noupdate -group $L -group RespInNoC ${m}/mshr_noc_resp_valid_i}
    catch {add wave -noupdate -group $L -group RespInNoC ${m}/mshr_noc_resp_ready_o}
    catch {add wave -noupdate -group $L -group RespInNoC ${m}/mshr_noc_resp_i}

    # Boundary 4: MSHR -> tiles (response egress / multicast drain)
    catch {add wave -noupdate -group $L -group RespOut ${m}/group_mshr_resp_valid_o}
    catch {add wave -noupdate -group $L -group RespOut ${m}/group_mshr_resp_ready_i}
    catch {add wave -noupdate -group $L -group RespOut ${m}/group_mshr_resp_o}

    # Internal response path (post-spill) — watch these for the wedge
    catch {add wave -noupdate -group $L -group RespPath ${m}/resp_in_valid}
    catch {add wave -noupdate -group $L -group RespPath ${m}/resp_in_ready}
    catch {add wave -noupdate -group $L -group RespPath ${m}/resp_in}
    catch {add wave -noupdate -group $L -group RespPath ${m}/resp_out_valid}
    catch {add wave -noupdate -group $L -group RespPath ${m}/resp_out_ready}
    catch {add wave -noupdate -group $L -group RespPath ${m}/resp_out}
    catch {add wave -noupdate -group $L -group RespPath ${m}/mshr_resp_slots}
    catch {add wave -noupdate -group $L -group RespPath ${m}/resp_capture_fire}

    # Response classification (bypass vs MSHR-managed, drain selection)
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_is_mshr}
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_mshr_id}
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_from_mshr}
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_from_bypass}
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_mshr_id_dbg}
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_sel_valid}
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_sel_mshr_id}
    catch {add wave -noupdate -group $L -group Classify ${m}/resp_sel_subreq_idx}
    return 1
}

# Optional first arg = a single group id; otherwise add all groups.
if {[info exists 1] && [string length [string trim $1]] > 0} {
    set n [add_group_mshr_wave $1 $NumX $NumY]
    puts "Added group-MSHR signals for group $1 ($n found)."
} else {
    set added 0
    for {set g 0} {$g < $NumGroups} {incr g} {
        incr added [add_group_mshr_wave $g $NumX $NumY]
    }
    puts "Added group-MSHR signals for $added groups."
}
