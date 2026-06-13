proc run_rtlmp {} {
  global design_name out_dir report_dir
  global rtlmp_fence rtlmp_keep_data rtlmp_max_num_level rtlmp_target_util

  set rtlmp_report_dir [file join $report_dir rtlmp]
  file mkdir $rtlmp_report_dir

  set cmd [list \
    rtl_macro_placer \
    -report_directory $rtlmp_report_dir \
    -target_util $rtlmp_target_util \
    -max_num_level $rtlmp_max_num_level \
  ]

  if {$rtlmp_keep_data} {
    lappend cmd -keep_clustering_data
  }

  if {$rtlmp_fence ne ""} {
    if {[llength $rtlmp_fence] != 4} {
      error "rtlmp_fence must be empty or {lx ly ux uy}; got: $rtlmp_fence"
    }
    lassign $rtlmp_fence lx ly ux uy
    lappend cmd -fence_lx $lx -fence_ly $ly -fence_ux $ux -fence_uy $uy
  }

  puts "Running RTLMP: $cmd"
  {*}$cmd

  write_db  [file join $out_dir "${design_name}.rtlmp.odb"]
  write_def [file join $out_dir "${design_name}.rtlmp.def"]
}
