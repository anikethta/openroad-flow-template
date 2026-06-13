# Standalone OpenROAD place-and-route script.
#
# Run with:
#   openroad scripts/pnr.tcl
#
# For bring-up, set flow_stop_after to one of:
#   link, rtlmp, floorplan, place, cts, route, finish

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
set sram_dir           [file join $project_dir build sram]
set rtlmp_tcl          [file join $script_dir rtlmp.tcl]

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

# Optional macro inputs. Generated OpenRAM SRAM collateral is discovered from
# build/sram by default. Override these lists if you want to use different
# macro views or corners.
set macro_lefs         [lsort [glob -nocomplain [file join $sram_dir "*.lef"]]]
set macro_liberties    [lsort [glob -nocomplain [file join $sram_dir "*_TT_1p8V_25C.lib"]]]
set floorplan_def      ""

# Hard macro placement entries. The default matches the SRAM test instance in
# build/synth/top_synth.v. Origin is in microns and is the macro lower-left.
set sram_macro_inst    "fifo_inst/sram_storage/u_macro"
set sram_macro_origin  {60.0 80.0}
set sram_macro_orient  R0
set sram_macro_status  FIRM
set macro_placements   [list \
  [dict create \
    name $sram_macro_inst \
    origin $sram_macro_origin \
    orientation $sram_macro_orient \
    status $sram_macro_status] \
]

# RTL macro placer. This is for RTLMP-guided clustering/planning of the
# standard-cell netlist, not for black-box hard macro integration.
set run_rtlmp          0
set rtlmp_keep_data    1
set rtlmp_target_util  0.25
set rtlmp_max_num_level 2
set rtlmp_fence        {380 80 640 300}

# Standard-cell placement regions. These are stronger than RTLMP guidance:
# matching instances are assigned to an OpenDB region/group that global
# placement honors as a placement fence.
set placement_regions  [list \
  [dict create \
    name storage_region \
    area {380 80 640 300} \
    inst_patterns {fifo_inst/storage_inst/*}] \
]

# Floorplan.
set site_name          "unithd"
set die_area           {0 0 700 500}
set core_area          {40 40 660 460}

# Routing.
set signal_layers      "met1-met5"
set clock_layers       "met3-met5"
set route_layer        "met3"
set pin_hor_layers     "met3"
set pin_ver_layers     "met2"
set pin_constraints    [list \
  [dict create region "left:*"  pins {din* rst wr_en rd_en}] \
  [dict create region "right:*" pins {dout* sram_test_dout* full empty}] \
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

# Bring-up control: link, rtlmp, floorplan, place, cts, route, finish.
set flow_stop_after    "finish"

# Optional command-line overrides, for example:
#   FLOW_STOP_AFTER=place RUN_RTLMP=0 openroad scripts/pnr.tcl
if {[info exists ::env(FLOW_STOP_AFTER)] && $::env(FLOW_STOP_AFTER) ne ""} {
  set flow_stop_after $::env(FLOW_STOP_AFTER)
}
if {[info exists ::env(RUN_RTLMP)] && $::env(RUN_RTLMP) ne ""} {
  set run_rtlmp $::env(RUN_RTLMP)
}
if {[info exists ::env(SRAM_MACRO_INST)] && $::env(SRAM_MACRO_INST) ne ""} {
  set sram_macro_inst $::env(SRAM_MACRO_INST)
}
if {[info exists ::env(SRAM_MACRO_ORIGIN)] && $::env(SRAM_MACRO_ORIGIN) ne ""} {
  set sram_macro_origin $::env(SRAM_MACRO_ORIGIN)
}
if {[info exists ::env(SRAM_MACRO_ORIENT)] && $::env(SRAM_MACRO_ORIENT) ne ""} {
  set sram_macro_orient $::env(SRAM_MACRO_ORIENT)
}
if {[info exists ::env(SRAM_MACRO_STATUS)] && $::env(SRAM_MACRO_STATUS) ne ""} {
  set sram_macro_status $::env(SRAM_MACRO_STATUS)
}
set macro_placements [list \
  [dict create \
    name $sram_macro_inst \
    origin $sram_macro_origin \
    orientation $sram_macro_orient \
    status $sram_macro_status] \
]

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

proc normalize_lef_dbu {input_lef output_lef dbu_per_micron} {
  set in_fp [open $input_lef r]
  set out_fp [open $output_lef w]
  while {[gets $in_fp line] >= 0} {
    regsub {DATABASE[ \t]+MICRONS[ \t]+[0-9]+[ \t]*;} $line "DATABASE MICRONS $dbu_per_micron ;" line
    puts $out_fp $line
  }
  close $in_fp
  close $out_fp
}

proc normalize_macro_lefs {macro_lefs dbu_per_micron output_dir} {
  file mkdir $output_dir
  set normalized_lefs [list]
  foreach lef $macro_lefs {
    set normalized_lef [file join $output_dir [file tail $lef]]
    normalize_lef_dbu $lef $normalized_lef $dbu_per_micron
    lappend normalized_lefs $normalized_lef
  }
  return $normalized_lefs
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
  add_global_connection -defer_connection -net $power_net -inst_pattern {.*} -pin_pattern {^vccd1$}
  add_global_connection -defer_connection -net $ground_net -inst_pattern {.*} -pin_pattern {^VSS$} -ground
  add_global_connection -defer_connection -net $ground_net -inst_pattern {.*} -pin_pattern {^VSSE$}
  add_global_connection -defer_connection -net $ground_net -inst_pattern {.*} -pin_pattern {^VGND$}
  add_global_connection -defer_connection -net $ground_net -inst_pattern {.*} -pin_pattern {^VNB$}
  add_global_connection -defer_connection -net $ground_net -inst_pattern {.*} -pin_pattern {^vssd1$}
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

proc create_placement_regions {} {
  global placement_regions

  if {[llength $placement_regions] == 0} {
    return
  }

  set block [ord::get_db_block]
  foreach region_cfg $placement_regions {
    set name [dict get $region_cfg name]
    set area [dict get $region_cfg area]
    set patterns [dict get $region_cfg inst_patterns]

    if {[llength $area] != 4} {
      error "Placement region $name area must be {lx ly ux uy}; got: $area"
    }

    lassign $area lx ly ux uy
    set group "NULL"
    set region "NULL"
    foreach existing_group [$block getGroups] {
      if {[$existing_group getName] eq $name} {
        set group $existing_group
        set region [$group getRegion]
        break
      }
    }

    if {$group == "NULL"} {
      set region [odb::dbRegion_create $block $name]
      if {$region == "NULL"} {
        error "Duplicate placement region name: $name"
      }

      odb::dbBox_create $region \
        [ord::microns_to_dbu $lx] \
        [ord::microns_to_dbu $ly] \
        [ord::microns_to_dbu $ux] \
        [ord::microns_to_dbu $uy]

      set group [odb::dbGroup_create $region $name]
      if {$group == "NULL"} {
        error "Duplicate placement group name: $name"
      }
    } elseif {$region == "NULL"} {
      error "Placement group $name already exists but has no region"
    }

    set matched 0
    set added 0
    foreach inst [$block getInsts] {
      set inst_name [$inst getName]
      foreach pattern $patterns {
        if {[string match $pattern $inst_name]} {
          if {[$inst getGroup] != $group} {
            $group addInst $inst
            incr added
          }
          incr matched
          break
        }
      }
    }

    if {$matched == 0} {
      error "Placement region $name matched no instances using patterns: $patterns"
    }
    puts "Placement region $name: matched $matched instances, added $added to {$area}"
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

if {$run_rtlmp} {
  require_file $rtlmp_tcl "RTLMP Tcl"
  source $rtlmp_tcl
}
require_file $netlist "Synthesized netlist"
require_file $sdc_file "SDC file"
require_file $tech_lef "Technology LEF"
require_files $cell_lefs "Cell LEF"
require_files $liberty_files "Liberty"
if {[llength $macro_placements] > 0} {
  require_files $macro_lefs "Macro LEF"
  require_files $macro_liberties "Macro Liberty"
}
require_optional_file $pdn_tcl "PDN Tcl"
if {$run_extraction} {
  require_file $rcx_rules_file "RCX rules file"
}
if {[llength $macro_lefs] > 0} {
  set macro_lefs [normalize_macro_lefs $macro_lefs 1000 [file join $out_dir macro_lefs]]
}

# -----------------------------------------------------------------------------
# Read design
# -----------------------------------------------------------------------------
foreach lib $liberty_files {
  read_liberty $lib
}
foreach lib $macro_liberties {
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

if {$run_rtlmp} {
  run_rtlmp
}
create_placement_regions
stop_after rtlmp

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
create_placement_regions
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
