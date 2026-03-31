// =============================================================================
// Module     : gpu_ctrl_axi_v1_0.v
// Project    : 2D GPU Accelerator — PYNQ-Z2
// Description: Top-level IP wrapper for Vivado IP Catalog packaging.
//              Wraps gpu_ctrl_axi.v so the IP packager sees the correct
//              AXI4-Lite bus interface and interrupt port naming.
//
// Vivado IP packager expects:
//   - All AXI4-Lite slave signals prefixed with s_axi_*
//   - Interrupt output named "interrupt"
// =============================================================================

`timescale 1ns / 1ps

module gpu_ctrl_axi_v1_0 #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5
)(
    // -------------------------------------------------------------------------
    // AXI4-Lite Slave Interface
    // -------------------------------------------------------------------------
    input  wire                          s_axi_aclk,
    input  wire                          s_axi_aresetn,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire [2:0]                    s_axi_awprot,
    input  wire                          s_axi_awvalid,
    output wire                          s_axi_awready,

    input  wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input  wire [3:0]                    s_axi_wstrb,
    input  wire                          s_axi_wvalid,
    output wire                          s_axi_wready,

    output wire [1:0]                    s_axi_bresp,
    output wire                          s_axi_bvalid,
    input  wire                          s_axi_bready,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire [2:0]                    s_axi_arprot,
    input  wire                          s_axi_arvalid,
    output wire                          s_axi_arready,

    output wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output wire [1:0]                    s_axi_rresp,
    output wire                          s_axi_rvalid,
    input  wire                          s_axi_rready,

    // -------------------------------------------------------------------------
    // Command outputs (connect to drawing_engine in block design)
    // -------------------------------------------------------------------------
    output wire        cmd_valid,
    output wire [1:0]  cmd_type,
    output wire [10:0] cmd_x0,
    output wire [10:0] cmd_y0,
    output wire [10:0] cmd_x1,
    output wire [10:0] cmd_y1,
    output wire [15:0] cmd_color,
    output wire [31:0] cmd_fb_base,
    output wire [15:0] cmd_fb_stride,

    // -------------------------------------------------------------------------
    // Status inputs (connect from drawing_engine)
    // -------------------------------------------------------------------------
    input  wire        engine_busy,
    input  wire        engine_done,

    // -------------------------------------------------------------------------
    // Interrupt output
    // -------------------------------------------------------------------------
    output wire        interrupt
);

    // Instantiate the actual implementation
    gpu_ctrl_axi #(
        .C_S_AXI_DATA_WIDTH (C_S_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH (C_S_AXI_ADDR_WIDTH)
    ) u_gpu_ctrl_axi (
        .S_AXI_ACLK    (s_axi_aclk),
        .S_AXI_ARESETN (s_axi_aresetn),

        .S_AXI_AWADDR  (s_axi_awaddr),
        .S_AXI_AWPROT  (s_axi_awprot),
        .S_AXI_AWVALID (s_axi_awvalid),
        .S_AXI_AWREADY (s_axi_awready),

        .S_AXI_WDATA   (s_axi_wdata),
        .S_AXI_WSTRB   (s_axi_wstrb),
        .S_AXI_WVALID  (s_axi_wvalid),
        .S_AXI_WREADY  (s_axi_wready),

        .S_AXI_BRESP   (s_axi_bresp),
        .S_AXI_BVALID  (s_axi_bvalid),
        .S_AXI_BREADY  (s_axi_bready),

        .S_AXI_ARADDR  (s_axi_araddr),
        .S_AXI_ARPROT  (s_axi_arprot),
        .S_AXI_ARVALID (s_axi_arvalid),
        .S_AXI_ARREADY (s_axi_arready),

        .S_AXI_RDATA   (s_axi_rdata),
        .S_AXI_RRESP   (s_axi_rresp),
        .S_AXI_RVALID  (s_axi_rvalid),
        .S_AXI_RREADY  (s_axi_rready),

        .cmd_valid     (cmd_valid),
        .cmd_type      (cmd_type),
        .cmd_x0        (cmd_x0),
        .cmd_y0        (cmd_y0),
        .cmd_x1        (cmd_x1),
        .cmd_y1        (cmd_y1),
        .cmd_color     (cmd_color),
        .cmd_fb_base   (cmd_fb_base),
        .cmd_fb_stride (cmd_fb_stride),

        .engine_busy   (engine_busy),
        .engine_done   (engine_done),

        .irq           (interrupt)
    );

endmodule
