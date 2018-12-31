#!/usr/bin/env taskrunner.tcl
# -*- coding: utf-8 -*-

proc cc args {exec gcc {*}$args}

dep add a.o {a.c a.h} {cc -c $< -o $@}

foreach k {b c} {
    dep add $k.o [list $k.c $k.h] {cc -c $< -o $@}
}

dep add main.o {main.c a.h b.h c.h} {cc -c $< -o $@}
dep add prog {main.o a.o b.o c.o} {cc $^ -o $@}

# You can extend TaskRunner here like this.
snit::method TaskRunner hello args {
    puts [list HELLO $args]
    return OK
}

# namespace ensemble configure dep -map \
#     [list {*}[namespace ensemble configure dep -map] \
#          hello2 [list apply [list {type selfns win self args} {
#              puts [list HELLO $args]
#              return OK
#          }] {*}[lrange [dict get [namespace ensemble configure dep -map] configurelist] 1 end]]]
if {[dep cget -debug]} {
    puts [list ::argv $::argv]
    
    puts [list targets: [dep target list]]
    
    foreach t [dep target list] {
        puts [list dependency of $t: {*}[dep dependency list $t]]
    }
}

dep dispatch $::argv {

    dep update prog

} clean {

    dep run file delete {*}[dep target list]

}

# Equivalent code of [dep dispatch ...]:
# 
# if {$::argv eq ""} {
#      dep update prog
# 
# } else {
#     switch [lindex $::argv 0] {
#         clean {
#             file delete {*}[dep target list]
#         }
#         default {
#             puts [dep {*}$::argv]
#         }
#     }
#  }
