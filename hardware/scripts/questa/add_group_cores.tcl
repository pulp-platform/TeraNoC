# add_group_cores.tcl
# Add the full core wave set for EVERY core in one group, to the CURRENT Wave window.
#
#   do ../scripts/questa/add_group_cores.tcl 30          ;# all tiles, all cores in group 30
#   do ../scripts/questa/add_group_cores.tcl 30 0 3      ;# tiles 0..3 only
#
# NOTE ON ARGUMENTS: Questa's `do` passes positional macro parameters $1..$9 plus $argc -- NOT
# a Tcl `argv` list. Referencing $2 when only one argument was given is an error, hence the
# $argc guards below.
#
# Counts come from the design (NumY, NumTilesPerGroup, NumCoresPerTile), so this works at 4x4
# and 8x8 unchanged. Each core goes through wave_core.tcl inside a catch: one missing or
# optimised-away core is skipped with a message rather than aborting the rest -- which is
# exactly the failure that truncated wave_core.tcl itself, where a bad `do` on line 57 cost
# every signal below it.
#
# COST -- read before running this on a live 8x8 sim. wave_core.tcl adds ~150 signals per core
# and a group holds 16 cores here, so "all cores" is roughly 2,400 signals. Each starts logging
# the moment it is added and slows the simulation for as long as it stays in the window. Prefer
# the tile range unless you need the whole group.

if {$argc >= 1} { set _g $1 } else { set _g 0 }

proc _agc_param {name dflt} {
    set v ""
    if {[catch {set v [examine -radix dec mempool_pkg::$name]}]} {
        catch {set v [examine -radix dec /mempool_pkg::$name]}
    }
    if {[catch {expr {$v + 0}}]} { return $dflt }
    return $v
}

set NumY  [_agc_param NumY 1]
set NumTG [_agc_param NumTilesPerGroup 1]
set NumCT [_agc_param NumCoresPerTile 1]

if {$argc >= 2} { set _t0 $2 } else { set _t0 0 }
if {$argc >= 3} { set _t1 $3 } else { set _t1 [expr {$NumTG - 1}] }
if {$_t1 >= $NumTG} { set _t1 [expr {$NumTG - 1}] }
if {$_t0 < 0}      { set _t0 0 }

set _n [expr {($_t1 - $_t0 + 1) * $NumCT}]
puts "add_group_cores: group $_g -> gen_groups_x\[[expr {$_g / $NumY}]\]/gen_groups_y\[[expr {$_g % $NumY}]\]"
puts "add_group_cores: tiles $_t0..$_t1 of $NumTG, $NumCT core(s)/tile -> $_n core(s), ~[expr {$_n * 150}] signals"

set _script [file join [file dirname [info script]] wave_core.tcl]
set _ok 0
for {set t $_t0} {$t <= $_t1} {incr t} {
    for {set c 0} {$c < $NumCT} {incr c} {
        if {[catch {do $_script $_g $t $c $NumY} _e]} {
            puts "add_group_cores: SKIPPED core\[$_g\]\[$t\]\[$c\] -- $_e"
        } else {
            incr _ok
        }
    }
    if {($t - $_t0) % 4 == 3} { puts "add_group_cores: ...through tile $t" }
}
catch {wave refresh}
puts "add_group_cores: added $_ok of $_n core(s) for group $_g"
