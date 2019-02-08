#!/usr/bin/env tclsh

package require fileutil

package require tcltest
namespace import tcltest::*

set testScript [file normalize [info script]]

test load "Make sure it is loadable." {
    source [file dirname [file dirname $testScript]]/TclTaskRunner.tcl
} ""

test has-comm "Make sure comm is loadable." {
    package require comm
    list
} ""

proc open_comm_kid {} {
    set kidChan [open |[info nameofexecutable] w+]
    fconfigure $kidChan -buffering line
    puts $kidChan [string trim {
        package require comm
        puts [::comm::comm self]
        vwait forever
    }]
    flush $kidChan
    list [gets $kidChan] $kidChan
}

set kidID ""
test has-kid "Start child comm process" -body {
    lassign [open_comm_kid] kidID kidChan
    # puts [list kidID $kidID]
    expr {[comm::comm send $kidID pid] == [pid $kidChan]}
} -result 1

set THEME comm
set C 0

test $THEME-comm-[incr C] "construct with -worker" -body {
    
    TclTaskRunner dep -quiet yes \
        -worker [list comm::comm send $kidID];# -debug 1

} -result ::dep
    
test $THEME-comm-[incr C] "Add target" -body {

    dep target add varX depends {} check {
        info exists ::varX
    } action {
        set ::varX [incr ::actionCount(varX)]
    }

    dep target add varY depends {} check {
        info exists ::varY
    } action {
        incr ::actionCount(varY)
        incr ::varY 10
    }
    
    dep target list
} -result {varX varY}

test $THEME-basic-[incr C] "target update" {

    dep target add varZ depends {varX varY} check {
        info exists ::varZ
    } action {
        incr ::actionCount(varZ)
        set ::varZ [expr {$::varX + $::varY}]
    }

    dep update varZ
    
    comm::comm send $kidID set varZ

} 11
