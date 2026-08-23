# add_rh_stall.tcl
# Wave set for the ZERO-TIMEOUT STALL (docs/benchmarks/8x8_scaleup/wedge_zero_timeout.md):
# response hazards pile up (RH STUCK, huge counts) while mshr_timeout stays 0 on every group,
# entries sit in hold with peers=0 and subs=1/16, and the FPU flatlines at ~0.1%.
# These are exactly the signals behind the [RH STUCK] $display at mempool_group_mshr.sv:2515,
# so the waveform explains the printed lines rather than duplicating them.
#
#   do ../scripts/questa/add_rh_stall.tcl            ;# group 0, MSHR entries 0..3
#   do ../scripts/questa/add_rh_stall.tcl 10         ;# group 10, entries 0..3
#   do ../scripts/questa/add_rh_stall.tcl 10 0 7     ;# group 10, entries 0..7
#
# Questa's `do` passes $1..$9 and $argc, not a Tcl argv -- hence the $argc guards.
# Every add is catch-wrapped: an optimised-away signal is skipped, never fatal.

if {$argc >= 1} { set _g $1 } else { set _g 0 }

proc _rh_param {name dflt} {
    set v ""
    if {[catch {set v [examine -radix dec mempool_pkg::$name]}]} {
        catch {set v [examine -radix dec /mempool_pkg::$name]}
    }
    if {[catch {expr {$v + 0}}]} { return $dflt }
    return $v
}
set NumX [_rh_param NumX 1]
set NumY [_rh_param NumY 1]

if {$argc >= 2} { set _e0 $2 } else { set _e0 0 }
if {$argc >= 3} { set _e1 $3 } else { set _e1 3 }

set gx [expr {$_g / $NumY}]
set gy [expr {$_g % $NumY}]
set m "sim:/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/gen_group_mshr/i_group_mshr"
set L "RH_G${_g}"

puts "add_rh_stall: group $_g -> gen_groups_x\[$gx\]/gen_groups_y\[$gy\], MSHR entries $_e0..$_e1"

# --- the probe's own counters: these ARE the [RH STUCK] line -------------------------------
# rh_cyc is the counter printed as cyc=. rh_age[e] is the age that crosses the report threshold;
# rh_byp/rh_stl are the byp=/stl= fields. rh_report_cnt rising fast IS the storm.
catch {add wave -noupdate -group $L -radix unsigned ${m}/rh_cyc}
catch {add wave -noupdate -group $L -radix unsigned ${m}/rh_report_cnt}
catch {add wave -noupdate -group $L -radix unsigned ${m}/rh_age}
catch {add wave -noupdate -group $L -radix unsigned ${m}/rh_byp}
catch {add wave -noupdate -group $L -radix unsigned ${m}/rh_stl}

# --- the knobs that decide when a held entry is released ------------------------------------
# cfg_hold_subs_single is the "/16" in subs=1/16. If the entry never reaches it and the timeout
# never fires, the entry waits forever -- that is the hypothesis this run is meant to test.
catch {add wave -noupdate -group $L -group Cfg -radix unsigned ${m}/cfg_hold_subs_single}
catch {add wave -noupdate -group $L -group Cfg -radix unsigned ${m}/cfg_hold_window_single}
catch {add wave -noupdate -group $L -group Cfg -radix unsigned ${m}/cfg_serve_timeout}
catch {add wave -noupdate -group $L -group Cfg ${m}/cfg_bankfull_bp}

# --- per-entry state: the fields the RH STUCK line prints ------------------------------------
for {set e $_e0} {$e <= $_e1} {incr e} {
    set E "${L}_e${e}"
    catch {add wave -noupdate -group $L -group $E ${m}/mshr_q\[$e\].state}
    catch {add wave -noupdate -group $L -group $E -radix hex      ${m}/mshr_q\[$e\].base_addr}
    catch {add wave -noupdate -group $L -group $E -radix unsigned ${m}/mshr_q\[$e\].tgt_group_id}
    catch {add wave -noupdate -group $L -group $E -radix unsigned ${m}/mshr_q\[$e\].sub_reqs_num}
    catch {add wave -noupdate -group $L -group $E ${m}/mshr_q\[$e\].sub_reqs}
}
catch {wave refresh}
puts "add_rh_stall: done. NOT waveable: peers, n_inv/n_wait/n_drain/n_hold/n_cach --"
puts "add_rh_stall:   those are automatic variables inside the probe's always block. Read them"
puts "add_rh_stall:   from the \[RH STUCK\] transcript lines, or derive the bank histogram from"
puts "add_rh_stall:   mshr_q\[*\].state across the entries you added."
