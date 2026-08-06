# Gowin EDA (proprietary) build flow, run headlessly via gw_sh.
#
# Alternative to scripts/build.sh (yosys+GHDL -> nextpnr-himbaechel ->
# apycula), which we could not get working end-to-end under Linux with
# oss-cad-suite. This uses the vendor toolchain directly instead:
# Gowin's own VHDL parser/synthesis -> Gowin P&R -> Gowin bitstream
# packer, all in one `run all`.
#
# Usage (from repo root):
#   "C:/Gowin/Gowin_V1.9.11.03_Education_x64/IDE/bin/gw_sh.exe" gowin/build.tcl
#
# Output: gowin/proj/impl/pnr/top.fs

set repo_root [file normalize [file dirname [info script]]/..]
set proj_dir  "${repo_root}/gowin/proj"

create_project -name mosaic -dir $proj_dir -pn GW2AR-LV18QN88C8/I7 -device_version C -force

# Same topological order as scripts/common.sh's RTL_FILES (deps before
# dependents) -- Gowin's parser is generally order-tolerant for VHDL,
# but keep it consistent with the known-good oss flow regardless.
foreach f {
  rtl/common/pkg_types.vhd
  rtl/common/pkg_protocol.vhd
  rtl/common/pkg_memmap.vhd
  rtl/pe/pe.vhd
  rtl/array/systolic_array.vhd
  rtl/array/array_ctrl.vhd
  rtl/mem/bram_sdp.vhd
  rtl/mem/scratchpad.vhd
  rtl/feeder/ws_weight_loader.vhd
  rtl/feeder/skew_feeder.vhd
  rtl/feeder/result_drainer.vhd
  rtl/ctrl/crc8.vhd
  rtl/uart/uart_rx.vhd
  rtl/uart/uart_tx.vhd
  rtl/uart/sync_fifo.vhd
  rtl/ctrl/cmd_processor.vhd
  rtl/common/pulse_stretch.vhd
  rtl/top/clk_reset_gen.vhd
  rtl/top/top.vhd
} {
  add_file "${repo_root}/${f}"
}

add_file "${repo_root}/constraints/tangnano20k.cst"

set_option -top_module top
set_option -vhdl_std vhd2008

run all

puts "== Gowin build finished =="
puts "bitstream: ${proj_dir}/mosaic/impl/pnr/mosaic.fs"
