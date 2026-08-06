# Bring-up debug builds -- see rtl/top/uart_wire_test.vhd and
# rtl/top/uart_echo_test.vhd for what these isolate. Not part of the
# normal build (gowin/build.tcl builds the real "top").
#
# Usage (from repo root):
#   "<gowin>/IDE/bin/gw_sh.exe" gowin/build_uart_test.tcl wire   # test 1: raw pin passthrough
#   "<gowin>/IDE/bin/gw_sh.exe" gowin/build_uart_test.tcl echo   # test 2: real uart_rx/uart_tx FSMs
#
# Output: gowin/proj_<which>/<which>/impl/pnr/<which>.fs

set which [lindex $::argv 0]
if {$which eq ""} { set which "wire" }

if {$which eq "wire"} {
  set top_module "uart_wire_test"
  set extra_files {
    rtl/top/uart_wire_test.vhd
  }
} elseif {$which eq "echo"} {
  set top_module "uart_echo_test"
  set extra_files {
    rtl/uart/uart_rx.vhd
    rtl/uart/uart_tx.vhd
    rtl/top/clk_reset_gen.vhd
    rtl/top/uart_echo_test.vhd
  }
} else {
  error "unknown test '$which', expected 'wire' or 'echo'"
}

set repo_root [file normalize [file dirname [info script]]/..]
set proj_dir  "${repo_root}/gowin/proj_${which}"

create_project -name $top_module -dir $proj_dir -pn GW2AR-LV18QN88C8/I7 -device_version C -force

foreach f $extra_files {
  add_file "${repo_root}/${f}"
}
add_file "${repo_root}/constraints/tangnano20k.cst"

set_option -top_module $top_module
set_option -vhdl_std vhd2008

run all

puts "== Gowin build finished ($which) =="
puts "bitstream: ${proj_dir}/${top_module}/impl/pnr/${top_module}.fs"
