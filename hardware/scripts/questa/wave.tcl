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

add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/snitch_utilization
add wave -noupdate -group Utilization /mempool_tb/instruction_handshake
add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/lsu_utilization
add wave -noupdate -group Utilization /mempool_tb/lsu_handshake
add wave -noupdate -group Utilization -color {Cornflower Blue} -format Analog-Step -height 84 -max $num_cores -radix unsigned /mempool_tb/lsu_pressure
add wave -noupdate -group Utilization /mempool_tb/lsu_request
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
  # These are the output ports of the group module
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
proc add_group_mshr_wave {g NumX NumY} {
    set gx [expr {$g / $NumX}]
    set gy [expr {$g % $NumY}]
    set m "sim:/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/gen_group_mshr/i_group_mshr"
    # Skip groups/configs without a group MSHR instance.
    if {[catch {examine ${m}/mshr_q_valid}]} { return }
    set L "MSHR_G${g}_X${gx}Y${gy}"

    # --- Entry table (state / base_addr / resp_buf_cnt / sub_reqs / beat_pending ...) ---
    catch {add wave -noupdate -group $L -group Entries ${m}/mshr_q_valid}
    catch {add wave -noupdate -group $L -group Entries ${m}/mshr_q}
    catch {add wave -noupdate -group $L -group Entries ${m}/mshr_resp_inflight}

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

for {set g 0} {$g < $NumGroups_noc} {incr g} {
    add_group_mshr_wave $g $NumX_noc $NumY_noc
}


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
foreach global_core {204 205 203 202 201 206 87 78 223 47 151 69 116 247 95 94 92 23 62 61 222 127 134 133 186} {
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
