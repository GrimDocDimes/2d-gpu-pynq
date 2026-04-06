# =============================================================================
# package_ip.tcl — Auto-package gpu_ctrl_axi as a Vivado IP
# Run this ONCE (or whenever HDL changes) to regenerate component.xml:
#
#   vivado -mode batch -source scripts/package_ip.tcl
#
# This uses Vivado's ipx:: engine so the generated component.xml is always
# schema-valid for whatever Vivado version you're running.
# =============================================================================

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT_DIR   [file dirname $SCRIPT_DIR]
set IP_DIR     "${ROOT_DIR}/ip_repo/gpu_ctrl_axi_1.0"
set PART       "xc7z020clg400-1"

puts "INFO: Packaging gpu_ctrl_axi IP from: ${IP_DIR}"

# --------------------------------------------------------------------------
# Open an in-memory project just for packaging (no .xpr written)
# --------------------------------------------------------------------------
create_project -in_memory -part ${PART}

# Read the two HDL source files
read_verilog "${IP_DIR}/hdl/gpu_ctrl_axi.v"
read_verilog "${IP_DIR}/hdl/gpu_ctrl_axi_v1_0.v"

update_compile_order -fileset sources_1

# --------------------------------------------------------------------------
# Package — writes component.xml into $IP_DIR
# --------------------------------------------------------------------------
ipx::package_project \
    -root_dir    ${IP_DIR} \
    -vendor      grimdocdimes.com \
    -library     user \
    -taxonomy    /UserIP \
    -import_files \
    -force

set core [ipx::current_core]

# --------------------------------------------------------------------------
# Set core metadata
# --------------------------------------------------------------------------
set_property version          {1.0}             $core
set_property display_name     {GPU Control AXI} $core
set_property description      {AXI4-Lite slave register file for the 2D GPU drawing engine. Exposes 8 control/status registers to ARM PS and drives the PL drawing engine.} $core
set_property company_url      {https://github.com/GrimDocDimes/2d-gpu-pynq} $core
set_property supported_families {zynq Production} $core

# --------------------------------------------------------------------------
# Infer AXI4-Lite bus interface from port names
# --------------------------------------------------------------------------
ipx::infer_bus_interface \
    {s_axi_awaddr s_axi_awprot s_axi_awvalid s_axi_awready
     s_axi_wdata  s_axi_wstrb  s_axi_wvalid  s_axi_wready
     s_axi_bresp  s_axi_bvalid s_axi_bready
     s_axi_araddr s_axi_arprot s_axi_arvalid s_axi_arready
     s_axi_rdata  s_axi_rresp  s_axi_rvalid  s_axi_rready} \
    xilinx.com:interface:aximm_rtl:1.0 \
    [ipx::current_core]

# Associate clock with AXI interface
ipx::infer_bus_interface {s_axi_aclk}   xilinx.com:signal:clock_rtl:1.0   [ipx::current_core]
ipx::infer_bus_interface {s_axi_aresetn} xilinx.com:signal:reset_rtl:1.0   [ipx::current_core]
ipx::infer_bus_interface {interrupt}     xilinx.com:signal:interrupt_rtl:1.0 [ipx::current_core]

# Set clock association on S_AXI
set axi_intf [ipx::get_bus_interfaces S_AXI -of_objects $core]
if {$axi_intf ne ""} {
    set_property interface_mode slave $axi_intf
}

set clk_intf [ipx::get_bus_interfaces s_axi_aclk -of_objects $core]
if {$clk_intf ne ""} {
    set_property value S_AXI   [ipx::add_bus_parameter ASSOCIATED_BUSIF $clk_intf]
    set_property value s_axi_aresetn [ipx::add_bus_parameter ASSOCIATED_RESET $clk_intf]
}

# --------------------------------------------------------------------------
# xgui TCL file
# --------------------------------------------------------------------------
set xgui_file [ipx::add_file_set xilinx_xpgui_view_fileset $core]
set_property type    GTOP [ipx::add_file xgui/gpu_ctrl_axi_v1_0.tcl $xgui_file]

# --------------------------------------------------------------------------
# Save
# --------------------------------------------------------------------------
ipx::create_xgui_files $core
ipx::update_checksums  $core
ipx::save_core         $core

close_project

puts ""
puts "======================================================================"
puts " IP packaged successfully!"
puts " component.xml written to: ${IP_DIR}/component.xml"
puts " Now run: vivado -mode batch -source scripts/build_project.tcl"
puts "======================================================================"
