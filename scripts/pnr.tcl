# Standalone OpenROAD place-and-route script.
#
# Run with:
#   openroad scripts/pnr.tcl
#
# For bring-up, set flow_stop_after to one of:
#   link, floorplan, place, cts, route, finish

# -----------------------------------------------------------------------------
# User config
# -----------------------------------------------------------------------------
set script_dir [file dirname [file normalize [info script]]]
set project_dir [file dirname $script_dir]

set design_name        "top"
set top_module         "top"
set netlist            [file join $project_dir build synth top_synth.v]
set sdc_file           [file join $project_dir src constraints.sdc]
set out_dir            [file join $project_dir build pnr]

# Innovus-style aliases for the same core setup knobs.
set design_toplevel    $top_module
set init_verilog       $netlist
set init_top_cell      $top_module

set pdk_root           [file normalize [file join ~ pdks]]
set skywater_pdk       [file join $pdk_root skywater-pdk]
set sky130_hd          [file join $skywater_pdk libraries sky130_fd_sc_hd latest]

# Physical views.
set tech_lef           [file join $sky130_hd tech sky130_fd_sc_hd.tlef]
set cell_lefs          [list]
set extra_cell_lefs    [list \
  [file join $sky130_hd cells diode sky130_fd_sc_hd__diode_2.magic.lef] \
  [file join $sky130_hd cells tapvpwrvgnd sky130_fd_sc_hd__tapvpwrvgnd_1.magic.lef] \
]
foreach lef [lsort [glob -nocomplain [file join $sky130_hd cells * "*.lef"]]] {
  set cell_dir [file tail [file dirname $lef]]
  if {![string match "*.magic.lef" $lef] \
      && ![string match "*isowell*" $lef] \
      && ![regexp {^(diode|tap(vgnd2?|vpwrvgnd)?)$} $cell_dir]} {
    lappend cell_lefs $lef
  }
}
foreach lef $extra_cell_lefs {
  lappend cell_lefs $lef
}
set liberty_files      [list \
  [file join $sky130_hd timing sky130_fd_sc_hd__tt_025C_1v80.lib] \
]

# Optional macro inputs. Use macro placement DEF before tapcell/PDN when needed.
set macro_lefs         [list]
set floorplan_def      ""
set macro_placements   [list]
# Example macro placement entry:
# lappend macro_placements [dict create \
#   name "u_sram" origin {40.0 120.0} orientation R0 status FIRM]

# Floorplan.
set site_name          "unithd"
set die_area           {0 0 300 300}
set core_area          {20 20 280 280}

# Routing.
set signal_layers      "met1-met5"
set clock_layers       "met3-met5"
set route_layer        "met3"
set pin_hor_layers     "met3"
set pin_ver_layers     "met2"
set pin_constraints    [list \
  [dict create region "left:*"  pins {din* rst wr_en rd_en flush}] \
  [dict create region "right:*" pins {dout* full empty}] \
  [dict create region "top:*"   pins {clk}] \
]

# Clock tree, fillers, tap/endcap, antenna.
set clock_port         "clk"
set cts_buf            "sky130_fd_sc_hd__clkbuf_4"
set cts_buf_list       [list sky130_fd_sc_hd__clkbuf_4 sky130_fd_sc_hd__clkbuf_8]
set filler_cells       [list "sky130_fd_sc_hd__fill_*"]
set tapcell_args       [list \
  -distance 14 \
  -tapcell_master sky130_fd_sc_hd__tapvpwrvgnd_1 \
  -endcap_master sky130_fd_sc_hd__decap_3 \
]
set antenna_cell       "sky130_fd_sc_hd__diode_2"

# PDN. Prefer a known-good PDK/platform PDN file. If pdn_tcl is empty, this
# script expects pdn_inline_script below to contain valid OpenROAD PDN commands.
set power_net          "VPWR"
set ground_net         "VGND"
set init_pwr_net       $power_net
set init_gnd_net       $ground_net
set voltage_domain     "CORE"
set pdn_tcl            ""
set pdn_inline_script  {
  define_pdn_grid -name grid -voltage_domains @VOLTAGE_DOMAIN@
  add_pdn_stripe -grid grid -layer met1 -width 0.48 -pitch 5.44 -offset 0 -followpins
  add_pdn_stripe -grid grid -layer met4 -width 1.600 -pitch 27.140 -offset 13.570
  add_pdn_stripe -grid grid -layer met5 -width 1.600 -pitch 27.200 -offset 13.600
  add_pdn_connect -grid grid -layers {met1 met4}
  add_pdn_connect -grid grid -layers {met4 met5}

  # Macro grids are harmless when there are no macros and mirror the
  # OpenROAD Sky130HD reference PDN setup.
  define_pdn_grid -name CORE_macro_grid_1 -voltage_domains @VOLTAGE_DOMAIN@ -macro \
    -orient {R0 R180 MX MY} -halo {0.0 0.0 0.0 0.0} -default -grid_over_boundary
  add_pdn_connect -grid CORE_macro_grid_1 -layers {met4 met5}

  define_pdn_grid -name CORE_macro_grid_2 -voltage_domains @VOLTAGE_DOMAIN@ -macro \
    -orient {R90 R270 MXR90 MYR90} -halo {0.0 0.0 0.0 0.0} -default -grid_over_boundary
  add_pdn_connect -grid CORE_macro_grid_2 -layers {met4 met5}
}

# Optional extraction. Requires a compatible RCX rules file.
set run_extraction     0
set rcx_rules_file     ""

# Bring-up control: link, floorplan, place, cts, route, finish.
set flow_stop_after    "finish"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
proc require_file {path label} {
  if {$path eq "" || ![file exists $path]} {
    error "$label does not exist: $path"
  }
}

proc require_files {paths label} {
  if {[llength $paths] == 0} {
    error "$label list is empty"
  }
  foreach path $paths {
    require_file $path $label
  }
}

proc require_optional_file {path label} {
  if {$path ne ""} {
    require_file $path $label
  }
}

proc stop_after {stage} {
  global flow_stop_after out_dir design_name
  if {$flow_stop_after eq $stage} {
    write_db [file join $out_dir "${design_name}.${stage}.odb"]
    write_def [file join $out_dir "${design_name}.${stage}.def"]
    puts "Stopped after stage: $stage"
    exit
  }
}

proc write_report {path body} {
  file mkdir [file dirname $path]
  if {[llength [info commands redirect]] != 0} {
    redirect -file $path $body
  } elseif {[llength [info commands redirect_file]] != 0} {
    redirect_file $path $body
  } else {
    set fp [open $path w]
    puts $fp "OpenROAD report redirection is unavailable in this build."
    puts $fp "Command was: $body"
    close $fp
    puts "WARNING: report redirection unavailable; printing report to console: $body"
    uplevel 1 $body
  }
}

proc dict_get_default {dict_value key default_value} {
  if {[dict exists $dict_value $key]} {
    return [dict get $dict_value $key]
  }
  return $default_value
}

# OpenROAD equivalent of the Innovus globalNetConnect/applyGlobalNets setup.
proc connect_global_nets {} {
  global ground_net power_net voltage_domain
  add_global_connection -defer_connection -net $power_net -inst_pattern {.*} -pin_pattern {^VDD$} -power
  add_global_connection -defer_connection -net $power_net -inst_pattern {.*} -pin_pattern {^VDDPE$}
  add_global_connection -defer_connection -net $power_net -inst_pattern {.*} -pin_pattern {^VDDCE$}
  add_global_connection -defer_connection -net $power_net -inst_pattern {.*} -pin_pattern {^VPWR$}
  add_global_connection -defer_connection -net $power_net -inst_pattern {.*} -pin_pattern {^VPB$}
  add_global_connection -defer_connection -net $ground_net -inst_pattern {.*} -pin_pattern {^VSS$} -ground
  add_global_connection -defer_connection -net $ground_net -inst_pattern {.*} -pin_pattern {^VSSE$}
  add_global_connection -defer_connection -net $ground_net -inst_pattern {.*} -pin_pattern {^VGND$}
  add_global_connection -defer_connection -net $ground_net -inst_pattern {.*} -pin_pattern {^VNB$}
  global_connect
  set_voltage_domain -name $voltage_domain -power $power_net -ground $ground_net
}

proc run_pdn {} {
  global pdn_inline_script pdn_tcl voltage_domain
  if {$pdn_tcl ne ""} {
    source $pdn_tcl
  } elseif {[string trim $pdn_inline_script] ne ""} {
    set rendered_pdn [string map [list @VOLTAGE_DOMAIN@ $voltage_domain] $pdn_inline_script]
    uplevel #0 $rendered_pdn
  } else {
    error "No PDN setup found. Set pdn_tcl or pdn_inline_script."
  }
  pdngen
}

# OpenROAD equivalent of Innovus placeInstance for hard/firm macro placement.
proc place_macros {} {
  global macro_placements
  foreach macro $macro_placements {
    set name [dict get $macro name]
    set origin [dict get $macro origin]
    set orientation [dict_get_default $macro orientation R0]
    set status [dict_get_default $macro status FIRM]
    place_inst -name $name -origin $origin -orientation $orientation -status $status
  }
}

# OpenROAD equivalent of the Innovus editPin groups.
proc apply_pin_constraints {} {
  global pin_constraints
  foreach group $pin_constraints {
    set_io_pin_constraint \
      -region [dict get $group region] \
      -pin_names [dict get $group pins] \
      -group
  }
}

proc make_sky130_tracks {} {
  # Track pitch/offset values mirror sky130_fd_sc_hd.tlef.
  make_tracks li1  -x_pitch 0.46 -x_offset 0.23 -y_pitch 0.34 -y_offset 0.17
  make_tracks met1 -x_pitch 0.34 -x_offset 0.17 -y_pitch 0.34 -y_offset 0.17
  make_tracks met2 -x_pitch 0.46 -x_offset 0.23 -y_pitch 0.46 -y_offset 0.23
  make_tracks met3 -x_pitch 0.68 -x_offset 0.34 -y_pitch 0.68 -y_offset 0.34
  make_tracks met4 -x_pitch 0.92 -x_offset 0.46 -y_pitch 0.92 -y_offset 0.46
  make_tracks met5 -x_pitch 3.40 -x_offset 1.70 -y_pitch 3.40 -y_offset 1.70
}

# -----------------------------------------------------------------------------
# Validate inputs
# -----------------------------------------------------------------------------
file mkdir $out_dir
set report_dir [file join $out_dir reports]
file mkdir $report_dir

require_file $netlist "Synthesized netlist"
require_file $sdc_file "SDC file"
require_file $tech_lef "Technology LEF"
require_files $cell_lefs "Cell LEF"
require_files $liberty_files "Liberty"
foreach lef $macro_lefs {
  require_file $lef "Macro LEF"
}
require_optional_file $pdn_tcl "PDN Tcl"
if {$run_extraction} {
  require_file $rcx_rules_file "RCX rules file"
}

# -----------------------------------------------------------------------------
# Read design
# -----------------------------------------------------------------------------
foreach lib $liberty_files {
  read_liberty $lib
}

read_lef $tech_lef
foreach lef $cell_lefs {
  read_lef $lef
}
foreach lef $macro_lefs {
  read_lef $lef
}

read_verilog $netlist
link_design $top_module
connect_global_nets
read_sdc $sdc_file

write_report [file join $report_dir link_checks.rpt] {
  report_check_types -max_slew -max_capacitance -max_fanout -violators
}
stop_after link

# -----------------------------------------------------------------------------
# Floorplan and routing setup
# -----------------------------------------------------------------------------
initialize_floorplan -site $site_name -die_area $die_area -core_area $core_area
make_sky130_tracks

if {$floorplan_def ne ""} {
  read_def $floorplan_def
}
place_macros

set_routing_layers -signal $signal_layers -clock $clock_layers
set_wire_rc -signal -layer $route_layer
set_wire_rc -clock -layer $route_layer

tapcell {*}$tapcell_args
run_pdn

apply_pin_constraints
place_pins \
  -hor_layers $pin_hor_layers \
  -ver_layers $pin_ver_layers \
  -write_pin_placement [file join $out_dir "${design_name}.pin_placement.tcl"]

write_def [file join $out_dir "${design_name}.floorplan.def"]
stop_after floorplan

# -----------------------------------------------------------------------------
# Placement
# -----------------------------------------------------------------------------
global_placement -routability_driven -density 0.65
repair_design
detailed_placement
check_placement -verbose

write_def [file join $out_dir "${design_name}.placed.def"]
stop_after place

# -----------------------------------------------------------------------------
# CTS and timing repair
# -----------------------------------------------------------------------------
repair_clock_inverters
clock_tree_synthesis -root_buf $cts_buf -buf_list $cts_buf_list
repair_clock_nets
detailed_placement

set_propagated_clock [all_clocks]
estimate_parasitics -placement
repair_timing
detailed_placement
check_placement -verbose

write_def [file join $out_dir "${design_name}.cts.def"]
stop_after cts

# -----------------------------------------------------------------------------
# Routing
# -----------------------------------------------------------------------------
pin_access
global_route -guide_file [file join $out_dir "${design_name}.route_guide"]

if {$antenna_cell ne ""} {
  repair_antennas -iterations 5 $antenna_cell
} else {
  repair_antennas -iterations 5
}

detailed_route -output_drc [file join $report_dir "${design_name}.route_drc.rpt"]
filler_placement {*}$filler_cells
check_placement -verbose

if {$run_extraction} {
  define_process_corner -ext_model_index 0 X
  extract_parasitics -ext_model_file $rcx_rules_file
}

write_def [file join $out_dir "${design_name}.routed.def"]
stop_after route

# -----------------------------------------------------------------------------
# Final checks and outputs
# -----------------------------------------------------------------------------
write_db      [file join $out_dir "${design_name}.odb"]
write_def     [file join $out_dir "${design_name}.def"]
write_verilog [file join $out_dir "${design_name}.routed.v"]
write_sdc     [file join $out_dir "${design_name}.sdc"]

write_report [file join $report_dir worst_slack_max.rpt] {
  report_worst_slack -max
}
write_report [file join $report_dir worst_slack_min.rpt] {
  report_worst_slack -min
}
write_report [file join $report_dir tns.rpt] {
  report_tns
}
write_report [file join $report_dir checks.rpt] {
  report_check_types -max_slew -max_capacitance -max_fanout -violators
}
write_report [file join $report_dir setup_checks.rpt] {
  report_checks -path_delay max
}
write_report [file join $report_dir hold_checks.rpt] {
  report_checks -path_delay min
}

puts "PnR complete."
puts "Outputs: $out_dir"
