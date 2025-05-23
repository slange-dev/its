proc log_progress {x} {
    puts ""
    puts "$x"
    puts [exec date]
    puts ""
}

log_progress "ENTERING MAIN BUILD SCRIPT"

puts ""
puts "BUILDING $mchn ITS"
puts ""

# If the environment variable BASICS is set to "yes", only build
# the basics; ITS, tools, infastructure.
if {![info exists env(BASICS)]} {
    set env(BASICS) "no"
}

# If the MACSYMA environment variable is set, then we'll use
# it later to decide whether to build Macsyma.  If it is not set,
# maintain current behavior of building Macsyma.

if {![info exists env(MACSYMA)]} {
    set env(MACSYMA) "yes"
}

# If the NODUMP environment variable is set, don't do the final full
# dump.

proc cleanup {} {
    global spawn_id
    close -i $spawn_id
    sleep 1
    exec kill [exp_pid $spawn_id]
}

proc abort {} {
    puts ""
    puts "The last command timed out."
    exit 1
}

exit -onexit cleanup
trap {exit 1} {SIGINT SIGTERM}

proc type s {
    sleep .1
    foreach c [split $s ""] {
        send -- $c
        if [string match {[a-zA-Z0-9]} $c] {
	    expect -nocase $c
	} else {
	    expect "?"
	}
	sleep .03
    }
}

proc respond { w r } {
    expect -exact $w
    type $r
}

proc patch_its_and_go {} {
    # Disable SYSJOB output (e.g. "IT IS NOW ...") that appears at random
    # places during the build process.
    respond "\n" "styo+2/popj p,\r"
    respond "\n" "\033g"
}

proc pdset {} {
    expect "IN OPERATION"
    sleep 1
    type "\032"

    respond "Fair" ":pdset\r"
    set t [timestamp]
    respond "PDSET" [expr [timestamp -seconds $t -format "%Y"] / 100]C
    type [timestamp -seconds $t -format "%y%m%dD"]
    type [timestamp -seconds $t -format "%H%M%ST"]
    type "!."
    expect -exact "DAYLIGHT SAVINGS TIME?  " {
        type "N"
        expect "\n"
    } "\n" {
    }
    type "Q"
    expect ":KILL"
}

proc shutdown {} {
    global emulator_escape
    respond "*" ":lock\r"
    respond "_" "5kill"
    respond "GO DOWN?\r\n" "y"
    respond "BRIEF MESSAGE" "\003"
    respond "_" "q"
    expect ":KILL"
    respond "*" ":logout\r"
    respond "SHUTDOWN COMPLETE" $emulator_escape
}

proc ip_address {string} {
    set x 0
    set octets [lreverse [split $string .]]
    for {set i 0} {$i < 4} {incr i} {
	incr x [expr {256 ** $i * [lindex $octets $i]}]
    }
    format "%o" $x
}

# Respond to the output from (load ...).
proc respond_load { r } {
    expect -re {[\r\n][0-9]+\.? *[\r\n]}
    type $r
}

proc build_macsyma_portion {} {
    respond "*" "complr\013"
    respond "_" "\007"
    respond "*" "(load \"liblsp;iota\")"
    respond_load "(load \"maxtul;docgen\")"
    respond_load "(load \"maxtul;mcl\")"
    respond_load "(load \"maxdoc;mcldat\")"
    respond_load "(load \"libmax;module\")"
    respond_load "(load \"libmax;maxmac\")"
    respond_load "(progn (print (todo)) (print (todoi)) \"=Build=\")"
    expect "=Build="
    respond "\r" "(mapcan "
    type "#'(lambda (x) (cond ((not (memq x\r"
    type "'(DUMMY)\r"
    type ")) (doit x)))) (append todo todoi))"
    set timeout 1000
    expect {
	";BKPT" {
	    type "(quit)"
	}
        "NIL" {
	    type "(quit)"
	}
    }
    set timeout 100
}

set timeout 100
proc setup_timeout {} {
    # Don't do this until after you've called "spawn", otherwise it'll cause a
    # read from stdin which will return EOF if stdin isn't a tty.
    expect_after timeout abort
}

proc mkdir {name} {
    respond "*" ":print $name;..new. (udir)\r"
    expect "FILE NOT FOUND"
    type ":vk\r"
}

proc move_to_klfe {file} {
    copy_to_klfe $file
    respond "*" ":delete $file\r"
}

# Install an ARPANET server.
proc arpanet {rfc file} {
    # Dynamic Modeling uses demons, signaled from ATSIGN NETRFC.
    # Others do not.
    global mchn
    if [string equal "$mchn" "DM"] {
        respond "*" ":link sys;atsign $rfc, $file\r"
    } else {
        respond "*" ":link device;lbsign $rfc, $file\r"
    }
}

proc midas {target source {action ""}} {
    respond "*" ":midas ${target}_$source\r"
    eval $action
    expect ":KILL"
}

proc midast {target source {action ""}} {
    midas "/t $target" $source $action
}

proc omidas {target source {action ""}} {
    respond "*" ":midas;324 ${target}_$source\r"
    eval $action
    expect ":KILL"
}

proc oomidas {version target source {action ""}} {
    respond "*" ":midas;$version\r"
    respond "MIDAS.$version" "${target}_$source\r"
    eval $action
    expect ":KILL"
}

proc macro10 {target sources} {
    respond "*" ":macro\r"
    respond "*" "$target=$sources\r"
    expect "CORE USED"
    respond "*" "\003"
    respond "*" ":kill\r"
}

proc palx {target sources {actions ""}} {
    respond "*" ":palx ${target}_$sources\r"
    eval $actions
    expect ":KILL"
}

proc macn11 {target sources {actions ""}} {
    respond "*" ":macn11\r"
    respond "*" "${target}_$sources\r"
    eval $actions
    expect "CORE USED"
    respond "*" "\003"
    respond "*" ":kill\r"
}

proc loader {files} {
    respond "*" ":dec sys:loader\r"
    respond "*" "$files/g\r"
    expect "EXIT"
}

proc linker {files} {
    respond "*" ":dec sys:link\r"
    respond "*" "$files/go\r"
    expect "EXIT" {
        return
    } "%LNKNED" {
        # Sometimes there is this error; workaround is to retry.
        respond "*" "$files/go\r"
        expect "EXIT"
    }
}

proc decuuo {file {dump ":pdump"}} {
    respond "*" ":start 45\r"
    respond "Command:" "d"
    respond "*" "$dump $file\r"
    respond "*" ":kill\r"
}

proc cwd {directory} {
    respond "*" ":cwd $directory\r"
}

set ip [ip_address [lindex $argv 0]]
set gw [ip_address [lindex $argv 1]]

source $build/mark.tcl
source $build/basics.tcl

if {$env(BASICS)!="yes"} {
    source $build/misc.tcl
    source $build/$cpu/processor.tcl
    source $build/lisp.tcl
    source $build/haunt.tcl
    if {$env(MACSYMA)=="yes"} {
	source $build/macsyma.tcl
    }
    source $build/scheme.tcl
    source $build/dm.tcl
    source $build/muddle.tcl
    source $build/zork.tcl
    source $build/sail.tcl
    source $build/typeset.tcl
    source $build/shrdlu.tcl
}

bootable_tapes

# Make BACKUP directory and copy some important files there.

mkdir "backup"

respond "*" ":copy .; @ its, dsk0: backup;\r"
respond "*" ":copy .; @ ddt, dsk0: backup;\r"
respond "*" ":copy .; @ $salv, dsk0: backup;\r"
respond "*" ":copy sys; ts ddt, dsk0: backup;\r"
respond "*" ":copy sys; ts dump, dsk0: backup;\r"
respond "*" ":copy sys; ts midas, dsk0: backup;\r"

if [file exists $build/mchn/$mchn/custom.tcl] {
    source $build/mchn/$mchn/custom.tcl
}

# Set timestamp for current uptime record.
respond "*" ":create sys;record time\r"
respond "for help" "\003"
expect ":KILL"
respond "*" ":sfdate sys;record time, 0/0/00\r"

if {![info exists env(NODUMP)]} {
    # make output.tape
    respond "*" $emulator_escape
    create_tape "$out/output.tape"
    type ":dump\r"
    respond "_" "dump links full list\r"
    respond "LIST DEV =" "tty\r"
    respond "TAPE NO=" "1\r"
    expect -timeout 6000 "REEL"
    respond "_" "rewind\r"
    respond "_" "icheck\r"
    expect -timeout 6000 "_"
    type "quit\r"
}

shutdown
quit_emulator

puts ""
puts "MAIN BUILD SCRIPT DONE"
puts [exec date]
