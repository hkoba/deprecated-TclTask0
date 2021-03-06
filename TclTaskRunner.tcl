#!/usr/bin/env tclsh
# -*- coding: utf-8 -*-

# This code is ispired from make.awk, originally found in:
# http://www.cs.bell-labs.com/cm/cs/awkbook/
# http://www.cs.bell-labs.com/cm/cs/who/bwk/awkcode.txt

package require snit
package require struct::list
package require fileutil

namespace eval TclTaskRunner {
    ::variable scriptFn [::fileutil::fullnormalize [info script]]
    ::variable libDir [file dirname $scriptFn]

    source $libDir/helper/util.tcl

    namespace export *
}

source $TclTaskRunner::libDir/helper/namespace-util.tcl

snit::macro TclTaskRunner::Macro {} {
    option -quiet no
    option -dryrun no
    option -log-fh stdout
    option -log-prefix "# "
    option -debug 0
    option -debug-fh stdout

    option -known-keys ""; # For user extended keys
    variable myKnownKeysDict [dict create]
    typevariable ourRequiredKeysList [set KEYS [list action]]
    typevariable ourKnownKeysList [list {*}$KEYS depends check]

    option -indent "  "

    variable myDeps [dict create]

    variable myActualConfig [dict create]
    variable myKnownConfig [dict create]
    variable myConfigReader ""

    option -worker-depth 0
    option -in-worker no
    variable myWorker ""

    #========================================
    constructor args {
        set worker [from args -worker ""]

        $self configurelist $args
        
        $self worker install $worker
    }

    method source taskFile {
        if {![file exists $taskFile]} {
            error "Can't find $taskFile"
        }
        set taskFile [file normalize $taskFile]
        pushd_scope prevDir [file dirname $taskFile]
        if {$options(-debug)} {
            puts "sourcing $taskFile"
        }

        $type apply-in-ns $selfns {self type selfns} [list source $taskFile]\
            $self $type $selfns
    }
    
    method import taskFile {
        $type apply-in-ns $selfns {self type selfns} [list source $taskFile]\
            $self $type $selfns
    }

    #========================================

    method yes {depth args} {$self dputs $depth {*}$args; expr {"yes"}}
    method no {depth args} {$self dputs $depth {*}$args; expr {"no"}}

    method dputs {depth args} {$self dputsLevel 1 $depth {*}$args}
    method dputsLevel {level depth args} {
        if {$options(-debug) < $level} return
        set indent [string repeat $options(-indent) $depth]
        foreach line [split $args \n] {
            puts $options(-debug-fh) "$indent#| $line"
        }
    }

    #========================================

    method {target add} {target args} {
        if {[dict exists $myDeps $target]} {
            error "Task $target is multiply defined!"
        }
        # XXX: [llength $args] == 1 form.
        set dict [dict create {*}$args]
        if {[set errors [$self task verify $dict]] ne ""} {
            error "Task $target has error: $errors"
        }
        dict set myDeps $target $dict
    }

    # Shorthand form of target add.
    method add {target depends {action ""} args} {
        $self target add $target depends $depends action $action {*}$args
    }

    #========================================

    method build {{target ""} args} {
        $self update $target "" 0 {*}$args
    }

    method update {{target ""} {contextVar ""} {depth 0} args} {
        if {$contextVar ne ""} {
            # Called from dependency.
            upvar 1 $contextVar ctx
        } else {
            # Root of this update.
            set ctx [$self context new {*}$args]
        }
        
        if {$depth == 0 && $target eq ""} {
            set target [lindex [$self target list] end]
        }

        if {![dict exists $myDeps $target]} {
            if {$contextVar eq ""} {
                error "Unknown file or target: $target"
            }
            return 0
        }

        if {! $depth} {
            $self worker sync
        }

        $self dputs $depth start updating $target

        dict lappend ctx examined $target

        set changed []
        dict set ctx visited $target 1
        set depends [$self target depends $target]
        foreach pred $depends {
            $self dputs $depth $target depends on $pred
            if {[set v [dict-default [dict get $ctx visited] $pred 0]] == 0} {
                $self update $pred ctx [expr {$depth+1}]
            } elseif {$v == 1} {
                error "Task $pred and $target are circularly defined!"
            }

            # If predecessor is younger than the target,
            # target should be refreshed.
            if {[set thisMtime [$self mtime ctx $target $depth]]
                < [set predMtime [$self mtime ctx $pred $depth]]} {
                lappend changed $pred
            } elseif {$predMtime == -Inf && $thisMtime != -Inf} {
                $self dputs $depth Not changed but infinitely old: $pred
                lappend changed $pred
            } else {
                $self dputs $depth Not changed $pred mtime $predMtime $target $thisMtime
            }
        }
        dict set ctx visited $target 2

        if {[if {[llength $changed]} {

            $self yes $depth do action $target because changed=($changed)

        } elseif {[llength $depends] == 0} {

            $self yes $depth do action $target because it has no dependencies

        } elseif {[$self mtime ctx $target $depth] == -Inf} {

            $self yes $depth do action $target because it is infinitely old

        } else {

            $self no $depth No need to update $target

        }]} {

            $self target try action ctx $target $depth
        }
        set ctx
    }

    method mtime {contextVar target depth} {
        upvar 1 $contextVar ctx
        if {[$self context fetch-state ctx $target mtime]} {
            return $mtime
        }
        if {[dict exists $myDeps $target check]} {
            $self target try check ctx $target $depth ""
            if {[$self context fetch-state ctx $target mtime]} {
                return $mtime
            } else {
                return -Inf
            }
        } else {
            if {[$self file exists $target]} {
                $self file mtime $target
            } elseif {[dict exists $myDeps $target]} {
                return -Inf
            } else {
                error "Unknown node or file: $target"
            }
        }
    }

    method file {cmd args} {
        {*}$myWorker [list file $cmd {*}$args]
    }

    #========================================

    method {target list} {} {dict keys $myDeps }
    method names {} { dict keys $myDeps }

    # synonyms of [$self target dependency $target]
    method {target deps} target {$self target dependency $target}
    method {target depends} target {$self target dependency $target}
    method {dependency list} target {$self target dependency $target}

    method {target dependency} target {
        dict-default [dict get $myDeps $target] depends []
    }

    method forget name {
        if {![dict exists $myDeps $name]} {
            return 0
        }
        dict unset myDeps $name
        return 1
    }

    #========================================

    method {target try action} {contextVar target depth} {
        upvar 1 $contextVar ctx
        
        if {[lindex [$self target try check ctx $target $depth no] 0]} return

        set script [$self target script-for action $target]
        if {$options(-quiet)} {
            $self dputs $depth target $target script $script
        } else {
            puts $options(-log-fh) "$options(-log-prefix)$script"
        }
        if {!$options(-dryrun)} {
            set res [$self worker apply-to $target $script]
            $self context set-state ctx $target action $res

            $self dputs $depth ==> $res

            # After action, do check should be called again.
            if {![lindex [$self target try check ctx $target $depth yes] 0]} {
                error "postcheck failed after action $target"
            }
	}
        dict lappend ctx updated $target
    }

    method {target try check} {contextVar target depth default} {
        if {[set script [$self target script-for check $target]] eq ""} {
            return $default
        }

        upvar 1 $contextVar ctx

        $self dputs $depth checking target $target

        set resList [$self worker apply-to $target $script]
        
        $self dputs $depth => target $target check-result $resList

        $self context set-state ctx $target check $resList
        if {$resList ne ""} {
            set rest [lassign $resList bool]
            if {$bool} {
                $self context set-state ctx $target mtime \
                    [set mtime [expr {[clock microseconds]/1000000.0}]]
                $self dputs $depth target mtime is updated: $target mtime $mtime
            }
        }
        set resList
    }

    method {target script-for action} target {
        $self script subst $target \
            [dict-default [dict get $myDeps $target] action ""]
    }

    method {target script-for check} target {
        $self script subst $target \
            [dict-default [dict get $myDeps $target] check ""]
    }

    #========================================
    method {task verify} dict {
        set errors []
        set missingKeys []
        if {![dict exists $dict depends] && ![dict exists $dict check]} {
            lappend errors "Either depends or check is required"
        }
        foreach k $ourRequiredKeysList {
            if {![dict exists $dict $k]} {
                lappend missingKeys $k
            }
        }
        if {$missingKeys ne ""} {
            lappend errors "Mandatory keys are missing: $missingKeys"
        }
        set unknownKeys []
        if {![dict size $myKnownKeysDict]} {
            foreach k [list {*}$options(-known-keys) {*}$ourKnownKeysList] {
                dict set myKnownKeysDict $k 1
            }
        }
        foreach k [dict keys $dict] {
            if {![dict exists $myKnownKeysDict $k]} {
                lappend unknownKeys $k
            }
        }
        if {$unknownKeys ne ""} {
            lappend errors "Unknown keys: $unknownKeys"
        }
        set errors
    }

    #========================================

    method {context new} args {
        if {[llength $args] % 2 != 0} {
            error "Odd number of context arguments: $args"
        }
        dict create {*}$args \
            visited [dict create] state [dict create] updated []
    }

    method {context set-state} {contextVar target key value} {
        upvar 1 $contextVar ctx
        dict set ctx state $target $key $value
    }

    method {context fetch-state} {contextVar target key} {
        upvar 1 $contextVar ctx
        upvar 1 $key result
        if {[dict exists $ctx state $target $key]} {
            set result [dict get $ctx state $target $key]
            return 1
        } else {
            return 0
        }
    }

    #========================================

    method {worker apply-to} {target script} {
        {*}$myWorker [list apply [list {self target} $script $selfns] \
                          $self $target]
    }

    method {worker install} worker {
        if {$worker eq ""} {
            set worker [if {!$options(-worker-depth) || $options(-in-worker)} {
                list interp eval {}
            } else {
                # To use separate interpreter, set -worker-depth to 1
                list [interp create] eval
            }]
        }

        install myWorker using set worker

        $self worker sync -init
    }

    method {worker is-self} {} {
        string equal $myWorker [list interp eval {}]
    }

    method {worker gen-remote-config} {} {
        set config [configlist $self]
        dict set config -in-worker yes
        dict set config -debug 0
        dict set config -quiet yes
        dict incr config -worker-depth
    }

    method {worker sync} {{mode ""}} {
        if {[$self worker is-self]} return
        if {$mode eq "-init"} {
            {*}$myWorker [list namespace eval :: [list package require snit]]

            {*}$myWorker [list namespace eval $type {}]
            {*}$myWorker [list namespace eval $selfns {}]

            {*}$myWorker [::namespace-util::definition-of-snit-macro ::TclTaskRunner::Macro]

            {*}$myWorker [${type}::definition]
            
            {*}$myWorker [list $type $self {*}[$self worker gen-remote-config]]
        } else {
            {*}$myWorker [list $self configurelist [$self worker gen-remote-config]]
            
            {*}$myWorker [::namespace-util::definition $type]
            
            {*}$myWorker [list namespace ensemble configure $self \
                              -map [namespace ensemble configure $self -map]]
        }
    }
    
    method {script subst} {target script args} {
        set deps [$self target depends $target]
        string map [list \
                        \$@ $target \
                        \$< [string trim [lindex $deps 0]] \
                        \$^ [lrange $deps 0 end] \
                        {*}$args
                       ] $script
    }

    #========================================
    typemethod parsePosixOpts {varName {dict {}}} {
        upvar 1 $varName opts

        for {} {[llength $opts]
                && [regexp {^--?([\w\-]+)(?:(=)(.*))?} [lindex $opts 0] \
                        -> name eq value]} {set opts [lrange $opts 1 end]} {
            if {$eq eq ""} {
                set value 1
            }
            dict set dict -$name $value
        }
        set dict
    }

    typemethod apply-in-ns {ns varList command args} {
        apply [list $varList $command $ns] {*}$args
    }

    typemethod {helper enable} file {
        $type extend-by $TclTaskRunner::libDir/helper/$file
    }
    
    typemethod extend-by file {
        $type apply-in-ns :: type [list source $file] $type
    }

    typemethod toplevel args {
        $type helper enable config.tcl
        $type helper enable extras.tcl

        set self ::dep
        $type $self -debug [default ::env(DEBUG) 0]\
            {*}[$type parsePosixOpts args]\

        if {[llength $args]} {
            set args [lassign $args taskFile]
        } else {
            set taskFile TclTask.tcl
        }

        $self configurelist [$type parsePosixOpts args]

        scope_guard args [list set ::argv $::argv]
        set ::argv $args

        $self source $taskFile
    }
}

proc ::TclTaskRunner::definition {} {
    return {
        snit::type TclTaskRunner {
            TclTaskRunner::Macro
        }
    }
}

eval [::TclTaskRunner::definition]

if {![info level] && [info script] eq $::argv0} {

    TclTaskRunner toplevel {*}$::argv

}
