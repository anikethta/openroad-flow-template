yosys -import

set script_dir [file dirname [file normalize [info script]]]
set project_dir [file dirname $script_dir]

set src_dir [file join $project_dir src rtl]
set build_dir [file join $project_dir build synth]
set report_dir [file join $build_dir reports]

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

set rtl_files [concat \
  [glob -nocomplain [file join $src_dir "*.sv"]] \
  [glob -nocomplain [file join $src_dir "*.v"]] \
]
set rtl_files [lsort -unique $rtl_files]

if {[llength $rtl_files] == 0} {
  error "No RTL files found in $src_dir"
}

puts "Project root: $project_dir"
puts "Top module:   $top_module"
puts "RTL files:    $rtl_files"
if {$liberty ne "" && [file exists $liberty]} {
  puts "Liberty:      $liberty"
} else {
  puts "Liberty:      not found; using generic Yosys mapping"
  set liberty ""
}

read_verilog -sv {*}$rtl_files
hierarchy -check -top $top_module
check

tee -o [file join $report_dir rtl_stat.rpt] stat

if {$liberty ne ""} {
  synth -top $top_module -flatten -noabc
  dfflibmap -liberty $liberty
  abc -liberty $liberty -D $clock_period_ps
  opt -fast
} else {
  synth -top $top_module -flatten
}

clean
opt
check

tee -o [file join $report_dir synth_stat.rpt] stat
if {$liberty ne ""} {
  tee -o [file join $report_dir area.rpt] stat -top $top_module -liberty $liberty
} else {
  tee -o [file join $report_dir area.rpt] stat -top $top_module -tech cmos
}
tee -o [file join $report_dir timing.rpt] sta
write_json [file join $build_dir "${top_module}.json"]
write_verilog -noattr -noexpr [file join $build_dir "${top_module}_synth.v"]
