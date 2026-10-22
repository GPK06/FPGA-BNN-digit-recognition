# Synthesis -> implementation -> bitstream for the Zedboard demo (PL only).
#   cd bnn_fpga ; vivado -mode batch -source scripts/vivado_build.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set pdir $root/vivado_impl

create_project -force bnn_zed $pdir -part xc7z020clg484-1
add_files -norecurse [glob $root/rtl/*.v]
add_files -norecurse [glob $root/mem/*.mem]      ;# found by $readmemb during synthesis
add_files -fileset constrs_1 -norecurse $root/constraints/zedboard.xdc
set_property top zed_demo_top [current_fileset]
update_compile_order -fileset sources_1

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
open_run impl_1
report_utilization    -file $pdir/utilization.rpt
report_timing_summary -file $pdir/timing.rpt
puts "Bitstream: $pdir/bnn_zed.runs/impl_1/zed_demo_top.bit"
