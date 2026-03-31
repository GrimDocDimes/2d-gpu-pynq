# ==============================================================================
# gpu_ctrl_axi_v1_0.tcl — Vivado xgui TCL for GPU Control AXI IP
# This file is loaded by Vivado when the IP is added to the IP Catalog.
# It defines the IP's GUI parameters (none currently — all fixed in RTL).
# ==============================================================================

proc init_gui { IPINST } {
    ipgui::add_param $IPINST -name "Component_Name"

    #------ AXI Data Width Parameter -------------------------------------------
    set Page0 [ipgui::add_page $IPINST -name "Page 0" -display_name "Configuration"]
    ipgui::add_param $IPINST -name "C_S_AXI_DATA_WIDTH" -parent ${Page0} \
        -display_name "AXI Data Width" \
        -widget comboBox
    ipgui::add_param $IPINST -name "C_S_AXI_ADDR_WIDTH" -parent ${Page0} \
        -display_name "AXI Address Width" \
        -widget comboBox
}

proc update_PARAM_VALUE.C_S_AXI_DATA_WIDTH { PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
    # Vivado callback — nothing to do for fixed 32-bit width
}

proc validate_PARAM_VALUE.C_S_AXI_DATA_WIDTH { PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
    return true
}

proc update_PARAM_VALUE.C_S_AXI_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
    # Address width is fixed at 5 bits (8 registers × 4 bytes = 32 bytes)
}

proc validate_PARAM_VALUE.C_S_AXI_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
    return true
}

proc update_MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH { \
    MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
    set_property value [get_property value ${PARAM_VALUE.C_S_AXI_DATA_WIDTH}] \
        ${MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH { \
    MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
    set_property value [get_property value ${PARAM_VALUE.C_S_AXI_ADDR_WIDTH}] \
        ${MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH}
}
