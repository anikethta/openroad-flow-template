yosys -import

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file dirname $script_dir]

set src_dir [file join $project_dir src rtl]
set build_dir [file join $project_dir build synth]
set report_dir [file join $build_dir reports]
set sram_dir [file join $project_dir build sram]

file mkdir $build_dir
file mkdir $report_dir

set top_module top
if {[info exists ::env(TOP)] && $::env(TOP) ne ""} {
  set top_module $::env(TOP)
}

set clock_period_ps 5000
if {[info exists ::env(CLOCK_PERIOD_PS)] && $::env(CLOCK_PERIOD_PS) ne ""} {
  set clock_period_ps $::env(CLOCK_PERIOD_PS)
}

set flatten 0
if {[info exists ::env(SYNTH_FLATTEN)] && $::env(SYNTH_FLATTEN) ne ""} {
  set flatten $::env(SYNTH_FLATTEN)
}

set pdk_root [file normalize [file join ~ pdks]]
if {[info exists ::env(PDK_ROOT)] && $::env(PDK_ROOT) ne ""} {
  set pdk_root [file normalize $::env(PDK_ROOT)]
}

proc first_existing_file {patterns} {
  foreach pattern $patterns {
    foreach path [glob -nocomplain $pattern] {
      if {[file isfile $path]} {
        return [file normalize $path]
      }
    }
  }
  return ""
}

proc liberty_cell_areas {path} {
  set areas [dict create]
  set current_cell ""
  set fp [open $path r]
  while {[gets $fp line] >= 0} {
    if {[regexp {^[ \t]*cell[ \t]*\([ \t]*([^ \t\)]+)[ \t]*\)} $line -> cell_name]} {
      set current_cell $cell_name
    } elseif {$current_cell ne "" && [regexp {^[ \t]*area[ \t]*:[ \t]*([0-9.eE+-]+)} $line -> area]} {
      dict set areas $current_cell $area
    }
  }
  close $fp
  return $areas
}

proc count_verilog_cell_instances {netlist cell_name} {
  set count 0
  set fp [open $netlist r]
  while {[gets $fp line] >= 0} {
    set fields [regexp -all -inline {\S+} $line]
    if {[llength $fields] >= 2 && [lindex $fields 0] eq $cell_name} {
      incr count
    }
  }
  close $fp
  return $count
}

set liberty ""
if {[info exists ::env(LIBERTY)] && $::env(LIBERTY) ne ""} {
  set liberty [file normalize $::env(LIBERTY)]
} elseif {[info exists ::env(SKY130_LIBERTY)] && $::env(SKY130_LIBERTY) ne ""} {
  set liberty [file normalize $::env(SKY130_LIBERTY)]
} else {
  set liberty [first_existing_file [list \
    [file join $pdk_root sky130A libs.ref sky130_fd_sc_hd lib sky130_fd_sc_hd__tt_025C_1v80.lib] \
    [file join $pdk_root sky130A libs.ref sky130_fd_sc_hd lib "*.lib"] \
    [file join $pdk_root skywater-pdk libraries sky130_fd_sc_hd latest timing sky130_fd_sc_hd__tt_025C_1v80.lib] \
    [file normalize [file join ~ pdks skywater-pdk libraries sky130_fd_sc_hd latest timing sky130_fd_sc_hd__tt_025C_1v80.lib]] \
    [file join $pdk_root skywater-pdk libraries sky130_fd_sc_hd latest timing "*.lib"] \
  ]]
}

set macro_liberties [list]
if {[info exists ::env(MACRO_LIBERTIES)] && $::env(MACRO_LIBERTIES) ne ""} {
  foreach macro_lib $::env(MACRO_LIBERTIES) {
    lappend macro_liberties [file normalize $macro_lib]
  }
} elseif {[info exists ::env(SRAM_LIBERTY)] && $::env(SRAM_LIBERTY) ne ""} {
  lappend macro_liberties [file normalize $::env(SRAM_LIBERTY)]
} else {
  set macro_liberties [lsort -unique [concat \
    [glob -nocomplain [file join $sram_dir "*_TT_1p8V_25C.lib"]] \
    [glob -nocomplain [file join $sram_dir "*_TT_*.lib"]] \
  ]]
}

set existing_macro_liberties [list]
foreach macro_lib $macro_liberties {
  if {[file exists $macro_lib]} {
    lappend existing_macro_liberties [file normalize $macro_lib]
  } else {
    puts "WARNING: macro Liberty not found; skipping: $macro_lib"
  }
}
set macro_liberties $existing_macro_liberties

set rtl_search_dirs [concat \
  [list $src_dir] \
  [glob -nocomplain -type d [file join $src_dir "*"]] \
]
set rtl_files [list]
foreach rtl_dir $rtl_search_dirs {
  set rtl_files [concat \
    $rtl_files \
    [glob -nocomplain [file join $rtl_dir "*.sv"]] \
    [glob -nocomplain [file join $rtl_dir "*.v"]] \
  ]
}
set rtl_files [lsort -unique $rtl_files]

if {[llength $rtl_files] == 0} {
  error "No RTL files found in $src_dir"
}

puts "Project root: $project_dir"
puts "Top module:   $top_module"
puts "RTL files:    $rtl_files"
puts "Flatten:      $flatten"
if {$liberty ne "" && [file exists $liberty]} {
  puts "Liberty:      $liberty"
} else {
  puts "Liberty:      not found; using generic Yosys mapping"
  set liberty ""
}
if {[llength $macro_liberties] > 0} {
  puts "Macro libs:   $macro_liberties"
} else {
  puts "Macro libs:   none"
}

read_verilog -sv {*}$rtl_files
hierarchy -check -top $top_module
check

tee -o [file join $report_dir rtl_stat.rpt] stat

if {$liberty ne ""} {
  if {$flatten} {
    synth -top $top_module -flatten -noabc
  } else {
    synth -top $top_module -noabc
  }
  dfflibmap -liberty $liberty
  abc -liberty $liberty -D $clock_period_ps
  hilomap \
    -hicell sky130_fd_sc_hd__conb_1 HI \
    -locell sky130_fd_sc_hd__conb_1 LO
  opt -fast
} else {
  if {$flatten} {
    synth -top $top_module -flatten
  } else {
    synth -top $top_module
  }
}

clean
opt
if {$flatten} {
  check
} else {
  puts "Skipping post-map Yosys check for hierarchy-preserved netlist; use OpenROAD link/checks for final validation."
}

tee -o [file join $report_dir synth_stat.rpt] stat
if {$liberty ne ""} {
  tee -o [file join $report_dir area.rpt] stat -top $top_module -hierarchy -liberty $liberty
  tee -o [file join $report_dir stdcell_area.rpt] stat -top $top_module -hierarchy -liberty $liberty
} else {
  tee -o [file join $report_dir area.rpt] stat -top $top_module -tech cmos
  tee -o [file join $report_dir stdcell_area.rpt] stat -top $top_module -tech cmos
}
if {$flatten} {
  tee -o [file join $report_dir timing.rpt] sta
} else {
  set fp [open [file join $report_dir timing.rpt] w]
  puts $fp "Yosys STA is skipped because SYNTH_FLATTEN=0 preserves hierarchy for RTLMP."
  puts $fp "Use OpenROAD timing reports from build/pnr/reports after place-and-route."
  close $fp
}
write_json [file join $build_dir "${top_module}.json"]
write_verilog -noattr -noexpr [file join $build_dir "${top_module}_synth.v"]

set macro_area_report [file join $report_dir macro_area.rpt]
set synth_netlist [file join $build_dir "${top_module}_synth.v"]
set fp [open $macro_area_report w]
if {[llength $macro_liberties] > 0} {
  puts $fp "Macro area report. Areas are read from macro Liberty files and instances are counted in ${top_module}_synth.v."
  puts $fp ""
  puts $fp [format "%-40s %10s %18s %18s %s" "Cell" "Instances" "Area/Instance" "Total Area" "Liberty"]
  puts $fp [string repeat "-" 120]
} else {
  puts $fp "No macro Liberty files found."
  puts $fp "Set SRAM_LIBERTY or MACRO_LIBERTIES, or generate SRAM libs under build/sram."
}

set grand_macro_area 0.0
foreach macro_lib $macro_liberties {
  set macro_areas [liberty_cell_areas $macro_lib]
  foreach macro_cell [dict keys $macro_areas] {
    set instances [count_verilog_cell_instances $synth_netlist $macro_cell]
    if {$instances > 0} {
      set area [dict get $macro_areas $macro_cell]
      set total_area [expr {$instances * $area}]
      set grand_macro_area [expr {$grand_macro_area + $total_area}]
      puts $fp [format "%-40s %10d %18.6f %18.6f %s" $macro_cell $instances $area $total_area $macro_lib]
    }
  }
}
if {[llength $macro_liberties] > 0} {
  puts $fp [string repeat "-" 120]
  puts $fp [format "%-40s %10s %18s %18.6f" "Total macro area" "" "" $grand_macro_area]
}
close $fp
