# Batch behavioural simulation in Vivado.
#   cd bnn_fpga ; vivado -mode batch -source scripts/vivado_sim.tcl
# (or in the Tcl console of the GUI:  source scripts/vivado_sim.tcl)
# Optional:  set ::env(BNN_TB) tb_zed_demo   to run the wrapper smoke test instead.
set root  [file normalize [file join [file dirname [info script]] ..]]
set tb    [expr {[info exists ::env(BNN_TB)] ? $::env(BNN_TB) : "tb_bnn_top"}]
set pdir  $root/vivado_sim

create_project -force bnn_sim $pdir -part xc7z020clg484-1
add_files -norecurse [glob $root/rtl/*.v]
add_files -fileset sim_1 -norecurse [list $root/sim/tb_bnn_top.v $root/sim/tb_zed_demo.v]
set memfiles [glob $root/mem/*.mem]
add_files -norecurse $memfiles
add_files -fileset sim_1 -norecurse $memfiles
set_property top $tb [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
update_compile_order -fileset sim_1
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]

# $readmemb/$readmemh use paths relative to the xsim run directory:
# compile first, copy the .mem files there explicitly, then elaborate + run.
launch_simulation -step compile
set simdir $pdir/bnn_sim.sim/sim_1/behav/xsim
foreach f $memfiles { file copy -force $f $simdir }
launch_simulation -step elaborate
launch_simulation -step simulate
close_sim
