# add_spatz_core.tcl
# Append Spatz vector-core debug signals to the CURRENT Wave window (no full reload).
# Run from the QuestaSim Tcl console (cwd = your build dir, e.g. hardware/build_X):
#     do ../scripts/questa/add_spatz_core.tcl              ;# group 0, tile 0, core 0
#     do ../scripts/questa/add_spatz_core.tcl 3 5 0        ;# group 3, tile 5, core 0
# Answers: what vector instruction is executing, why the core is stalled, and which lanes/FPUs
# do useful work each cycle. Safe on an already-populated wave (`add wave` appends); every add is
# catch-wrapped so missing/optimized signals are skipped, not fatal. Self-contained: does not
# depend on wave.tcl having been sourced. Keep in sync with add_spatz_core_wave in wave.tcl.

set NumX ""
set NumY ""
if {[catch {set NumX [examine -radix dec mempool_pkg::NumX]}]} {
  catch {set NumX [examine -radix dec /mempool_pkg::NumX]}
}
if {[catch {set NumY [examine -radix dec mempool_pkg::NumY]}]} {
  catch {set NumY [examine -radix dec /mempool_pkg::NumY]}
}
if {[catch {expr {$NumX + 0}}] || [catch {expr {$NumY + 0}}]} { set NumX 1; set NumY 1 }

proc add_spatz_core_wave {g t c NumX NumY} {
    # gx = g/NumY, gy = g%NumY -- BOTH divide by NumY. This read `g / $NumX` and was silently
    # wrong on any mesh where NumX != NumY: at 4x8 it addressed a different group and the
    # `catch {examine ...}` below then returned early, so the core was skipped with NO message.
    # wave_core.tcl (:6) and add_group_cores.tcl are the ground truth: both use NumY for each.
    set gx [expr {$g / $NumY}]
    set gy [expr {$g % $NumY}]
    set cc "sim:/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core"
    set s "${cc}/i_spatz"
    if {[catch {examine ${s}/i_controller/spatz_req_valid_o}]} { return }
    set L "SPATZ_G${g}_T${t}_C${c}"

    # Trace cycle counter FIRST: sp_cycle is the tracer's free-running counter and is the EXACT `cyc`
    # field in trace_spatz_{insn,cyc,fplsu}_hart_*.log (== the Snitch .dasm `cycle`). ns = 2*cyc + 10.
    catch {add wave -noupdate -group $L -radix unsigned ${cc}/sp_cycle}

    # Issue / decode: which vector instruction is executing + the in-flight id set.
    catch {add wave -noupdate -group $L -group Issue ${s}/i_controller/spatz_req_valid_o}
    catch {add wave -noupdate -group $L -group Issue ${s}/i_controller/spatz_req_o}
    catch {add wave -noupdate -group $L -group Issue ${s}/i_controller/running_insn_q}
    catch {add wave -noupdate -group $L -group Issue ${s}/i_controller/running_insn_full}
    # Stall + reason (issue stage + dependency scoreboard + FP sequencer).
    catch {add wave -noupdate -group $L -group Stall ${s}/i_controller/stall}
    catch {add wave -noupdate -group $L -group Stall ${s}/i_controller/vfu_stall}
    catch {add wave -noupdate -group $L -group Stall ${s}/i_controller/vlsu_stall}
    catch {add wave -noupdate -group $L -group Stall ${s}/i_controller/vsldu_stall}
    catch {add wave -noupdate -group $L -group Stall ${s}/i_controller/sb_port_has_deps_dbg}
    catch {add wave -noupdate -group $L -group Stall ${s}/i_controller/sb_port_enable_dbg}
    catch {add wave -noupdate -group $L -group Stall ${s}/gen_fpu_sequencer/i_fpu_sequencer/stall}
    catch {add wave -noupdate -group $L -group Stall ${s}/gen_fpu_sequencer/i_fpu_sequencer/lsu_stall}
    catch {add wave -noupdate -group $L -group Stall ${s}/gen_fpu_sequencer/i_fpu_sequencer/move_stall}
    catch {add wave -noupdate -group $L -group Stall ${s}/gen_fpu_sequencer/i_fpu_sequencer/operands_available}
    # VFU: per-lane IPU + per-FPU useful work.
    catch {add wave -noupdate -group $L -group VFU ${s}/i_vfu/state_q}
    catch {add wave -noupdate -group $L -group VFU ${s}/i_vfu/int_ipu_busy}
    catch {add wave -noupdate -group $L -group VFU ${s}/i_vfu/int_ipu_result_valid}
    catch {add wave -noupdate -group $L -group VFU ${s}/i_vfu/fpu_result_valid}
    catch {add wave -noupdate -group $L -group VFU ${s}/i_vfu/is_ipu_busy}
    catch {add wave -noupdate -group $L -group VFU ${s}/i_vfu/is_fpu_busy}
    catch {add wave -noupdate -group $L -group VFU ${s}/i_vfu/vfu_rsp_valid_o}
    # VLSU: memory-beat activity + FSM state.
    catch {add wave -noupdate -group $L -group VLSU ${s}/i_vlsu/state_q}
    catch {add wave -noupdate -group $L -group VLSU ${s}/i_vlsu/spatz_mem_req_valid_o}
    catch {add wave -noupdate -group $L -group VLSU ${s}/i_vlsu/spatz_mem_req_ready_i}
    catch {add wave -noupdate -group $L -group VLSU ${s}/i_vlsu/spatz_mem_rsp_valid_i}
    catch {add wave -noupdate -group $L -group VLSU ${s}/i_vlsu/commit_operation_valid}
    catch {add wave -noupdate -group $L -group VLSU ${s}/i_vlsu/vlsu_rsp_valid_o}
}

# Args: [group [tile [core]]], default 0 0 0.
# Questa's `do` passes POSITIONAL macro parameters $1..$9 plus $argc -- there is no Tcl `argv`
# here. Reading [lindex $argv 0] picked up whatever argv happened to hold (usually empty), so
# `do add_spatz_core.tcl 3 5 0` silently added group 0 tile 0 core 0 instead. Same trap already
# documented in add_group_cores.tcl.
set _g 0; set _t 0; set _c 0
if {$argc >= 1} { set _g $1 }
if {$argc >= 2} { set _t $2 }
if {$argc >= 3} { set _c $3 }
add_spatz_core_wave $_g $_t $_c $NumX $NumY
