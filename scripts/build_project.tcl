# =============================================================================
# build_project.tcl — Automated Vivado Block Design Builder
# Project   : 2D GPU Accelerator for PYNQ-Z2
# Vivado    : 2019.2+ (tested 2019.2, 2022.1, 2023.1)
#
# Usage (run from the repo root OR from scripts/ directory):
#   vivado -mode batch -source scripts/build_project.tcl
#
# Creates ./gpu_project/ with a complete block design and runs synthesis,
# implementation, and bitstream generation.
#
# Output files:
#   gpu_project/gpu_project.runs/impl_1/design_1_wrapper.bit
#   gpu_project/design_1.hwh   (hardware handoff — copy alongside .bit)
# =============================================================================

## ---- Project Settings -------------------------------------------------------
set PROJ_NAME  "gpu_project"
set PROJ_DIR   [file normalize "[pwd]/${PROJ_NAME}"]
set PART       "xc7z020clg400-1"   ;# PYNQ-Z2
set BOARD_PART "tul.com.tw:pynq-z2:part0:1.0"

## ---- Source Directories -----------------------------------------------------
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set ROOT_DIR   [file dirname $SCRIPT_DIR]
set HDL_DIR    "${ROOT_DIR}/hdl"
set IP_REPO    "${ROOT_DIR}/ip_repo"
set XDC_DIR    "${ROOT_DIR}/constraints"

## ---- Create Project ---------------------------------------------------------
create_project ${PROJ_NAME} ${PROJ_DIR} -part ${PART} -force
set_property board_part ${BOARD_PART} [current_project]

## ---- Add IP Repository ------------------------------------------------------
set_property ip_repo_paths ${IP_REPO} [current_project]
update_ip_catalog

## ---- Add HDL Sources --------------------------------------------------------
add_files -norecurse [glob ${HDL_DIR}/*.v]
set_property file_type {Verilog} [get_files [glob ${HDL_DIR}/*.v]]

## ---- Add Constraints --------------------------------------------------------
add_files -fileset constrs_1 -norecurse ${XDC_DIR}/pynq_z2.xdc

## ---- Create Block Design ----------------------------------------------------
create_bd_design "design_1"
update_compile_order -fileset sources_1

## ---- Zynq PS ----------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0

# Apply PYNQ-Z2 board preset
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} \
    [get_bd_cells processing_system7_0]

# Enable HP0 (high-performance slave — for AXI4 burst writes from drawing engine)
set_property -dict [list \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_FPGA1_PERIPHERAL_FREQMHZ {148} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {1} \
    CONFIG.PCW_IRQ_F2P_INTR {1} \
] [get_bd_cells processing_system7_0]

## ---- Processor System Reset -------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
               [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] \
               [get_bd_pins proc_sys_reset_0/ext_reset_in]

## ---- PS7 AXI port clocks (mandatory — must be driven by FCLK_CLK0) ----------
# GP0 master clock (PS → PL control path)
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
               [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK]
# HP0 slave clock (drawing engine DDR write path)
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
               [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK]
# NOTE: S_AXI_HP1_ACLK is connected below, after HP1 is enabled

## ---- AXI Interconnect (GP0 → GPU control registers) -----------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] \
    [get_bd_cells axi_interconnect_0]

connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] \
                    [get_bd_intf_pins axi_interconnect_0/S00_AXI]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
               [get_bd_pins axi_interconnect_0/ACLK] \
               [get_bd_pins axi_interconnect_0/S00_ACLK] \
               [get_bd_pins axi_interconnect_0/M00_ACLK]
connect_bd_net [get_bd_pins proc_sys_reset_0/interconnect_aresetn] \
               [get_bd_pins axi_interconnect_0/ARESETN] \
               [get_bd_pins axi_interconnect_0/S00_ARESETN] \
               [get_bd_pins axi_interconnect_0/M00_ARESETN]

## ---- GPU Control AXI IP -----------------------------------------------------
create_bd_cell -type ip -vlnv grimdocdimes.com:user:gpu_ctrl_axi_v1_0:1.0 gpu_ctrl_axi_0

connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M00_AXI] \
                    [get_bd_intf_pins gpu_ctrl_axi_0/s_axi]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
               [get_bd_pins gpu_ctrl_axi_0/s_axi_aclk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
               [get_bd_pins gpu_ctrl_axi_0/s_axi_aresetn]

## ---- Drawing Engine (RTL module) -------------------------------------------
create_bd_cell -type module -reference drawing_engine drawing_engine_0

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
               [get_bd_pins drawing_engine_0/clk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
               [get_bd_pins drawing_engine_0/rst_n]

# Command interface: GPU ctrl → Drawing engine
connect_bd_net [get_bd_pins gpu_ctrl_axi_0/cmd_valid]     [get_bd_pins drawing_engine_0/cmd_valid]
connect_bd_net [get_bd_pins gpu_ctrl_axi_0/cmd_type]      [get_bd_pins drawing_engine_0/cmd_type]
connect_bd_net [get_bd_pins gpu_ctrl_axi_0/cmd_x0]        [get_bd_pins drawing_engine_0/cmd_x0]
connect_bd_net [get_bd_pins gpu_ctrl_axi_0/cmd_y0]        [get_bd_pins drawing_engine_0/cmd_y0]
connect_bd_net [get_bd_pins gpu_ctrl_axi_0/cmd_x1]        [get_bd_pins drawing_engine_0/cmd_x1]
connect_bd_net [get_bd_pins gpu_ctrl_axi_0/cmd_y1]        [get_bd_pins drawing_engine_0/cmd_y1]
connect_bd_net [get_bd_pins gpu_ctrl_axi_0/cmd_color]     [get_bd_pins drawing_engine_0/cmd_color]
connect_bd_net [get_bd_pins gpu_ctrl_axi_0/cmd_fb_base]   [get_bd_pins drawing_engine_0/cmd_fb_base]
connect_bd_net [get_bd_pins gpu_ctrl_axi_0/cmd_fb_stride] [get_bd_pins drawing_engine_0/cmd_fb_stride]

# Status interface: Drawing engine → GPU ctrl
connect_bd_net [get_bd_pins drawing_engine_0/engine_busy] [get_bd_pins gpu_ctrl_axi_0/engine_busy]
connect_bd_net [get_bd_pins drawing_engine_0/engine_done] [get_bd_pins gpu_ctrl_axi_0/engine_done]

## ---- SmartConnect: Drawing engine AXI4 master → PS HP0 --------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] \
    [get_bd_cells smartconnect_0]

connect_bd_intf_net [get_bd_intf_pins drawing_engine_0/M_AXI] \
                    [get_bd_intf_pins smartconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M00_AXI] \
                    [get_bd_intf_pins processing_system7_0/S_AXI_HP0]

connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
               [get_bd_pins smartconnect_0/aclk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
               [get_bd_pins smartconnect_0/aresetn]

## ---- AXI VDMA (reads framebuffer → sends to HDMI TX) ----------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_vdma:6.3 axi_vdma_0
set_property -dict [list \
    CONFIG.c_include_s2mm {0} \
    CONFIG.c_mm2s_linebuffer_depth {512} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
] [get_bd_cells axi_vdma_0]

# VDMA control registers on AXI GP0 (add second MI port to interconnect)
set_property -dict [list CONFIG.NUM_MI {2}] [get_bd_cells axi_interconnect_0]

connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M01_AXI] \
                    [get_bd_intf_pins axi_vdma_0/S_AXI_LITE]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
               [get_bd_pins axi_vdma_0/s_axi_lite_aclk] \
               [get_bd_pins axi_vdma_0/m_axi_mm2s_aclk] \
               [get_bd_pins axi_vdma_0/m_axis_mm2s_aclk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
               [get_bd_pins axi_vdma_0/axi_resetn]
connect_bd_net [get_bd_pins axi_interconnect_0/M01_ACLK] \
               [get_bd_pins processing_system7_0/FCLK_CLK0]
connect_bd_net [get_bd_pins axi_interconnect_0/M01_ARESETN] \
               [get_bd_pins proc_sys_reset_0/peripheral_aresetn]

# VDMA read master → HP1 via SmartConnect
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_1
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] \
    [get_bd_cells smartconnect_1]

set_property -dict [list CONFIG.PCW_USE_S_AXI_HP1 {1}] \
    [get_bd_cells processing_system7_0]

# HP1 clock must be connected AFTER HP1 is enabled
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
               [get_bd_pins processing_system7_0/S_AXI_HP1_ACLK]

connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXI_MM2S] \
                    [get_bd_intf_pins smartconnect_1/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_1/M00_AXI] \
                    [get_bd_intf_pins processing_system7_0/S_AXI_HP1]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
               [get_bd_pins smartconnect_1/aclk]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
               [get_bd_pins smartconnect_1/aresetn]

## ---- Digilent rgb2dvi (HDMI TX) -------------------------------------------
# Requires Digilent IP repo: https://github.com/Digilent/vivado-library
# If not installed, VDMA M_AXIS_MM2S is left unconnected (warning only).
if { [catch {
    create_bd_cell -type ip -vlnv digilentinc.com:ip:rgb2dvi:1.4 rgb2dvi_0

    connect_bd_intf_net [get_bd_intf_pins axi_vdma_0/M_AXIS_MM2S] \
                        [get_bd_intf_pins rgb2dvi_0/RGB]

    # Pixel clock from FCLK_CLK1
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK1] \
                   [get_bd_pins rgb2dvi_0/PixelClk]

    # HDMI TX external ports
    make_bd_intf_pins_external [get_bd_intf_pins rgb2dvi_0/TMDS]

    puts "INFO: Digilent rgb2dvi IP added successfully."
} err] } {
    puts "WARNING: Digilent rgb2dvi IP not found — HDMI TX skipped."
    puts "WARNING: Install from https://github.com/Digilent/vivado-library and re-run."
    puts "WARNING: M_AXIS_MM2S left unconnected — add HDMI TX manually in GUI."
    # Do NOT make external — just leave M_AXIS_MM2S unconnected
}

## ---- IRQ: GPU done → PS IRQ_F2P[0] ----------------------------------------
connect_bd_net [get_bd_pins gpu_ctrl_axi_0/interrupt] \
               [get_bd_pins processing_system7_0/IRQ_F2P]

## ---- Address Assignment -----------------------------------------------------
# GPU control registers: 0x4300_0000 (64 KB)
assign_bd_address [get_bd_addr_segs gpu_ctrl_axi_0/s_axi/reg0]
set_property offset 0x43000000 \
    [get_bd_addr_segs processing_system7_0/Data/SEG_gpu_ctrl_axi_0_reg0]
set_property range 64K \
    [get_bd_addr_segs processing_system7_0/Data/SEG_gpu_ctrl_axi_0_reg0]

# VDMA registers: 0x4340_0000 (64 KB)
assign_bd_address [get_bd_addr_segs axi_vdma_0/S_AXI_LITE/Reg]
set_property offset 0x43400000 \
    [get_bd_addr_segs processing_system7_0/Data/SEG_axi_vdma_0_Reg]
set_property range 64K \
    [get_bd_addr_segs processing_system7_0/Data/SEG_axi_vdma_0_Reg]

# HP0 slave (drawing engine DDR writes): full 512 MB DDR window
assign_bd_address [get_bd_addr_segs processing_system7_0/S_AXI_HP0/HP0_DDR_LOWOCM]

# HP1 slave (VDMA DDR reads): full 512 MB DDR window
assign_bd_address [get_bd_addr_segs processing_system7_0/S_AXI_HP1/HP1_DDR_LOWOCM]

## ---- Validate and Save Block Design ----------------------------------------
validate_bd_design
save_bd_design

## ---- Create HDL Wrapper -----------------------------------------------------
make_wrapper -files [get_files design_1.bd] -top
add_files -norecurse ${PROJ_DIR}/${PROJ_NAME}.srcs/sources_1/bd/design_1/hdl/design_1_wrapper.v
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1

## ---- Run Synthesis ----------------------------------------------------------
puts "INFO: Starting synthesis..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if { [get_property PROGRESS [get_runs synth_1]] != "100%" } {
    error "ERROR: Synthesis failed. Check reports in ${PROJ_DIR}/${PROJ_NAME}.runs/synth_1/"
}

## ---- Run Implementation -----------------------------------------------------
puts "INFO: Starting implementation..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if { [get_property PROGRESS [get_runs impl_1]] != "100%" } {
    error "ERROR: Implementation failed. Check reports in ${PROJ_DIR}/${PROJ_NAME}.runs/impl_1/"
}

## ---- Export Hardware Handoff ------------------------------------------------
set BIT_FILE "${PROJ_DIR}/${PROJ_NAME}.runs/impl_1/design_1_wrapper.bit"
file copy -force $BIT_FILE ${PROJ_DIR}/gpu_accel.bit

## write_hw_platform is Vivado 2020+; use write_hwdef for 2019.x
set vivado_ver [version -short]
if { [string match "2019.*" $vivado_ver] || [string match "2018.*" $vivado_ver] } {
    write_hwdef -force -file ${PROJ_DIR}/gpu_accel.hdf
    puts "INFO: Hardware definition written: ${PROJ_DIR}/gpu_accel.hdf"
    puts "INFO: Extract the .hwh from the HDF using SDK or the Vitis HW export wizard."
} else {
    write_hw_platform -fixed -force -include_bit -file ${PROJ_DIR}/gpu_accel.xsa
    puts "INFO: XSA written: ${PROJ_DIR}/gpu_accel.xsa"
}

puts ""
puts "====================================================================="
puts " Build complete!"
puts " Bitstream : ${PROJ_DIR}/gpu_accel.bit"
if { [string match "2019.*" $vivado_ver] || [string match "2018.*" $vivado_ver] } {
    puts " HDF file  : ${PROJ_DIR}/gpu_accel.hdf (extract .hwh inside)"
} else {
    puts " XSA file  : ${PROJ_DIR}/gpu_accel.xsa (contains .hwh)"
}
puts " Copy .bit + .hwh to: /home/xilinx/jupyter_notebooks/gpu/"
puts "====================================================================="
