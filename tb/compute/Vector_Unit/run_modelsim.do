# ModelSim / Questa script for vec_simd_tb (interactive or GUI use).
#
# From the repository root:
#   vsim -do tb/compute/Vector_Unit/run_modelsim.do         (GUI)
#   vsim -c -do tb/compute/Vector_Unit/run_modelsim.do      (console)
# For the scripted regression with pass/fail exit status use run_tests.sh --sim modelsim.

if {[file exists work]} {
  vdel -lib work -all
}
vlib work

set src_list [open rtl/compute/Vector_Unit/vec_simd.f r]
set sources {}
foreach line [split [read $src_list] "\n"] {
  set line [string trim $line]
  if {$line ne "" && ![string match "//*" $line]} {
    lappend sources $line
  }
}
close $src_list

vlog -sv -work work {*}$sources tb/compute/Vector_Unit/vec_simd_tb.sv
vsim -work work vec_simd_tb
run -all
