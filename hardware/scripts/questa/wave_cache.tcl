# Copyright 2021 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Create cache for core $3 from group $1 tile $2 (core_id=NUM_CORES_PER_group*$1+NUM_CORES_PER_TILE*$2+$3)

set group ""
set tile  ""
set core  ""
set num_y ""
if {[info exists 1] && [info exists 2] && [info exists 3]} {
  set group $1
  set tile  $2
  set core  $3
  if {[info exists 4]} {
    set num_y $4
  }
} elseif {$argc >= 3} {
  set group [lindex $argv 0]
  set tile  [lindex $argv 1]
  set core  [lindex $argv 2]
  if {$argc >= 4} {
    set num_y [lindex $argv 3]
  }
} else {
  return
}
if {[catch {expr {$group + 0}}] || [catch {expr {$tile + 0}}] || [catch {expr {$core + 0}}]} {
  set nums {}
  foreach tok $argv {
    if {[regexp {^-?\d+$} $tok]} {
      lappend nums $tok
    }
  }
  if {[llength $nums] < 3} {
    return
  }
  set group [lindex $nums 0]
  set tile  [lindex $nums 1]
  set core  [lindex $nums 2]
}
if {$num_y eq "" || [catch {expr {$num_y + 0}}]} {
  if {[catch {set num_y [examine -radix dec mempool_pkg::NumY]}]} {
    catch {set num_y [examine -radix dec /mempool_pkg::NumY]}
  }
}
if {[catch {expr {$num_y + 0}}]} {
  set num_y 1
}
set group_x [expr {$group / $num_y}]
set group_y [expr {$group % $num_y}]
set base "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[$group_x\]/gen_groups_y\[$group_y\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[$tile\]/i_tile/gen_caches\[$core\]/i_snitch_icache"
if {[catch {examine -radix dec ${base}/NR_FETCH_PORTS}]} {
  return
}

add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] -divider Parameters
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] ${base}/NR_FETCH_PORTS
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] ${base}/L0_LINE_COUNT
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] ${base}/LINE_WIDTH
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] ${base}/LINE_COUNT
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] ${base}/SET_COUNT
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] ${base}/FETCH_DW
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] ${base}/FILL_AW
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] ${base}/FILL_DW
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] ${base}/EARLY_LATCH
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] ${base}/L0_EARLY_TAG_WIDTH
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] ${base}/ISO_CROSSING
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] -divider Signals
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] ${base}/*

for {set i 0} {$i < [examine -radix dec ${base}/NR_FETCH_PORTS]} {incr i} {
  add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] -group refill[$i] ${base}/gen_prefetcher[$i]/i_snitch_icache_l0/*
}

if {![catch {examine ${base}/gen_serial_lookup/i_lookup/lookup_valid}]} {
  add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] -group lookup  ${base}/gen_serial_lookup/i_lookup/*
} elseif {![catch {examine ${base}/i_lookup/lookup_valid}]} {
  add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] -group lookup  ${base}/i_lookup/*
}
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] -group handler ${base}/i_handler/*
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] -group handler ${base}/i_handler/pending_q
add wave -noupdate -group cache\[$group\]\[$tile\]\[$core\] -group refill  ${base}/i_refill/*
