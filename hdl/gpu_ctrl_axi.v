// =============================================================================
// Module     : gpu_ctrl_axi.v
// Project    : 2D GPU Accelerator — PYNQ-Z2
// Description: AXI4-Lite slave register file.
//              Exposes 8 × 32-bit control/status registers to ARM PS.
//              Generates draw commands and IRQ to PL drawing engine.
//
// Register map (base assigned in Vivado address editor, e.g. 0x4300_0000):
//   0x00 CTRL      [0]=START, [2:1]=CMD_TYPE, [31]=IRQ_EN
//   0x04 STATUS    [0]=BUSY,  [1]=DONE
//   0x08 X0_Y0     [10:0]=X0, [26:16]=Y0
//   0x0C X1_Y1     [10:0]=X1, [26:16]=Y1
//   0x10 COLOR     [15:0]=RGB565
//   0x14 FB_BASE   [31:0] physical framebuffer base address
//   0x18 FB_STRIDE [15:0] bytes per row (default 2560)
//   0x1C IRQ_CLR   write 1 to clear done IRQ
// =============================================================================

`timescale 1ns / 1ps

module gpu_ctrl_axi #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 5   // 32 bytes = 8 registers
)(
    // -------------------------------------------------------------------------
    // AXI4-Lite Slave interface
    // -------------------------------------------------------------------------
    input  wire                          S_AXI_ACLK,
    input  wire                          S_AXI_ARESETN,

    // Write address channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_AWADDR,
    input  wire [2:0]                    S_AXI_AWPROT,
    input  wire                          S_AXI_AWVALID,
    output reg                           S_AXI_AWREADY,

    // Write data channel
    input  wire [C_S_AXI_DATA_WIDTH-1:0] S_AXI_WDATA,
    input  wire [3:0]                    S_AXI_WSTRB,
    input  wire                          S_AXI_WVALID,
    output reg                           S_AXI_WREADY,

    // Write response channel
    output reg  [1:0]                    S_AXI_BRESP,
    output reg                           S_AXI_BVALID,
    input  wire                          S_AXI_BREADY,

    // Read address channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_ARADDR,
    input  wire [2:0]                    S_AXI_ARPROT,
    input  wire                          S_AXI_ARVALID,
    output reg                           S_AXI_ARREADY,

    // Read data channel
    output reg  [C_S_AXI_DATA_WIDTH-1:0] S_AXI_RDATA,
    output reg  [1:0]                    S_AXI_RRESP,
    output reg                           S_AXI_RVALID,
    input  wire                          S_AXI_RREADY,

    // -------------------------------------------------------------------------
    // Command outputs to Drawing Engine
    // -------------------------------------------------------------------------
    output reg         cmd_valid,    // 1-cycle pulse to start draw
    output reg [1:0]   cmd_type,     // 0=pixel, 1=line
    output reg [10:0]  cmd_x0,
    output reg [10:0]  cmd_y0,
    output reg [10:0]  cmd_x1,
    output reg [10:0]  cmd_y1,
    output reg [15:0]  cmd_color,
    output reg [31:0]  cmd_fb_base,
    output reg [15:0]  cmd_fb_stride,

    // -------------------------------------------------------------------------
    // Status inputs from Drawing Engine
    // -------------------------------------------------------------------------
    input  wire        engine_busy,
    input  wire        engine_done,  // 1-cycle pulse from engine

    // -------------------------------------------------------------------------
    // Interrupt output to PS (IRQ_F2P)
    // -------------------------------------------------------------------------
    output reg         irq
);

    // =========================================================================
    // Internal register file
    // =========================================================================
    reg [31:0] reg_ctrl;      // offset 0x00
    reg [31:0] reg_status;    // offset 0x04  (read-only, driven from engine)
    reg [31:0] reg_x0y0;      // offset 0x08
    reg [31:0] reg_x1y1;      // offset 0x0C
    reg [31:0] reg_color;     // offset 0x10
    reg [31:0] reg_fb_base;   // offset 0x14
    reg [31:0] reg_fb_stride; // offset 0x18
    // 0x1C = IRQ_CLR (write-only, no register needed)

    // =========================================================================
    // AXI4-Lite Write State Machine
    // =========================================================================
    reg        aw_active;   // address accepted, waiting for data
    reg [4:0]  aw_addr_r;   // latched write address

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_AWREADY <= 1'b0;
            S_AXI_WREADY  <= 1'b0;
            S_AXI_BVALID  <= 1'b0;
            S_AXI_BRESP   <= 2'b00;
            aw_active     <= 1'b0;
            cmd_valid     <= 1'b0;
            irq           <= 1'b0;
            // Register reset values
            reg_ctrl      <= 32'b0;
            reg_x0y0      <= 32'b0;
            reg_x1y1      <= 32'b0;
            reg_color     <= 32'hFFFF; // white default
            reg_fb_base   <= 32'h1000_0000;
            reg_fb_stride <= 32'd2560;
        end else begin
            cmd_valid <= 1'b0; // default: no command

            // ------------------------------------------------------------------
            // Latch write address
            // ------------------------------------------------------------------
            if (S_AXI_AWVALID && !aw_active) begin
                S_AXI_AWREADY <= 1'b1;
                aw_addr_r     <= S_AXI_AWADDR[4:0];
                aw_active     <= 1'b1;
            end else begin
                S_AXI_AWREADY <= 1'b0;
            end

            // ------------------------------------------------------------------
            // Accept write data and perform register write
            // ------------------------------------------------------------------
            if (S_AXI_WVALID && aw_active) begin
                S_AXI_WREADY <= 1'b1;
                aw_active    <= 1'b0;

                // Byte-enable aware write (uses WSTRB)
                case (aw_addr_r[4:2])
                    3'd0: begin // CTRL
                        if (S_AXI_WSTRB[0]) reg_ctrl[7:0]   <= S_AXI_WDATA[7:0];
                        if (S_AXI_WSTRB[3]) reg_ctrl[31:24] <= S_AXI_WDATA[31:24];
                        // Fire command on START bit
                        if (S_AXI_WDATA[0]) begin
                            cmd_type   <= S_AXI_WDATA[2:1];
                            cmd_valid  <= 1'b1;
                        end
                    end
                    3'd1: ; // STATUS read-only
                    3'd2: begin // X0_Y0
                        if (S_AXI_WSTRB[1:0] != 2'b00)
                            reg_x0y0[15:0]  <= S_AXI_WDATA[15:0];
                        if (S_AXI_WSTRB[3:2] != 2'b00)
                            reg_x0y0[31:16] <= S_AXI_WDATA[31:16];
                    end
                    3'd3: begin // X1_Y1
                        if (S_AXI_WSTRB[1:0] != 2'b00)
                            reg_x1y1[15:0]  <= S_AXI_WDATA[15:0];
                        if (S_AXI_WSTRB[3:2] != 2'b00)
                            reg_x1y1[31:16] <= S_AXI_WDATA[31:16];
                    end
                    3'd4: reg_color     <= S_AXI_WDATA; // COLOR
                    3'd5: reg_fb_base   <= S_AXI_WDATA; // FB_BASE
                    3'd6: reg_fb_stride <= S_AXI_WDATA; // FB_STRIDE
                    3'd7: if (S_AXI_WDATA[0]) irq <= 1'b0; // IRQ_CLR
                    default: ;
                endcase

                // Write response
                S_AXI_BVALID <= 1'b1;
                S_AXI_BRESP  <= 2'b00; // OKAY
            end else begin
                S_AXI_WREADY <= 1'b0;
            end

            // ------------------------------------------------------------------
            // Deassert BVALID when accepted
            // ------------------------------------------------------------------
            if (S_AXI_BVALID && S_AXI_BREADY) begin
                S_AXI_BVALID <= 1'b0;
            end

            // ------------------------------------------------------------------
            // IRQ generation
            // ------------------------------------------------------------------
            if (engine_done && reg_ctrl[31]) begin // IRQ_EN bit
                irq <= 1'b1;
            end
        end
    end

    // =========================================================================
    // AXI4-Lite Read State Machine
    // =========================================================================
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_ARREADY <= 1'b0;
            S_AXI_RVALID  <= 1'b0;
            S_AXI_RRESP   <= 2'b00;
            S_AXI_RDATA   <= 32'b0;
        end else begin
            if (S_AXI_ARVALID && !S_AXI_RVALID) begin
                S_AXI_ARREADY <= 1'b1;
                S_AXI_RVALID  <= 1'b1;
                S_AXI_RRESP   <= 2'b00;

                case (S_AXI_ARADDR[4:2])
                    3'd0: S_AXI_RDATA <= reg_ctrl;
                    3'd1: S_AXI_RDATA <= {30'b0, engine_done, engine_busy};
                    3'd2: S_AXI_RDATA <= reg_x0y0;
                    3'd3: S_AXI_RDATA <= reg_x1y1;
                    3'd4: S_AXI_RDATA <= reg_color;
                    3'd5: S_AXI_RDATA <= reg_fb_base;
                    3'd6: S_AXI_RDATA <= reg_fb_stride;
                    3'd7: S_AXI_RDATA <= {31'b0, irq};
                    default: S_AXI_RDATA <= 32'hDEAD_BEEF;
                endcase
            end else begin
                S_AXI_ARREADY <= 1'b0;
            end

            if (S_AXI_RVALID && S_AXI_RREADY)
                S_AXI_RVALID <= 1'b0;
        end
    end

    // =========================================================================
    // Output command latching (snapshot registers when cmd_valid fires)
    // =========================================================================
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            cmd_x0       <= 11'b0;
            cmd_y0       <= 11'b0;
            cmd_x1       <= 11'b0;
            cmd_y1       <= 11'b0;
            cmd_color    <= 16'hFFFF;
            cmd_fb_base  <= 32'h1000_0000;
            cmd_fb_stride<= 16'd2560;
        end else if (cmd_valid) begin
            cmd_x0        <= reg_x0y0[10:0];
            cmd_y0        <= reg_x0y0[26:16];
            cmd_x1        <= reg_x1y1[10:0];
            cmd_y1        <= reg_x1y1[26:16];
            cmd_color     <= reg_color[15:0];
            cmd_fb_base   <= reg_fb_base;
            cmd_fb_stride <= reg_fb_stride[15:0];
        end
    end

endmodule
