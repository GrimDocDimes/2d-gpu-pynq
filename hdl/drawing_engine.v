// =============================================================================
// Module     : drawing_engine.v
// Project    : 2D GPU Accelerator — PYNQ-Z2
// Description: Top-level drawing engine.  Instantiates and connects:
//                1. bresenham_core       — pixel coordinate generator
//                2. pixel_addr_calc      — DDR address + data packer
//                3. axi4_burst_writer    — AXI4 master write to DDR
//
//   Control interface : accepts cmd_* signals from gpu_ctrl_axi
//   AXI4 master port  : connect to PS HP0 via SmartConnect in block design
//
// Draw latency:
//   Pixel plot : ~5 cycles (INIT + addr calc pipeline + FIFO)
//   Line N px  : N cycles (Bresenham) + addr_calc 2-cycle delay + burst latency
// =============================================================================

`timescale 1ns / 1ps

module drawing_engine (
    input  wire        clk,
    input  wire        rst_n,

    // -------------------------------------------------------------------------
    // Command interface (from gpu_ctrl_axi)
    // -------------------------------------------------------------------------
    input  wire        cmd_valid,
    input  wire [1:0]  cmd_type,     // 0=pixel, 1=line
    input  wire [10:0] cmd_x0, cmd_y0,
    input  wire [10:0] cmd_x1, cmd_y1,
    input  wire [15:0] cmd_color,
    input  wire [31:0] cmd_fb_base,
    input  wire [15:0] cmd_fb_stride,

    // -------------------------------------------------------------------------
    // Status outputs (to gpu_ctrl_axi)
    // -------------------------------------------------------------------------
    output wire        engine_busy,
    output reg         engine_done,  // 1-cycle pulse when draw complete

    // -------------------------------------------------------------------------
    // AXI4 Master Write (connect to SmartConnect → PS HP0)
    // -------------------------------------------------------------------------
    output wire [31:0] M_AXI_AWADDR,
    output wire [7:0]  M_AXI_AWLEN,
    output wire [2:0]  M_AXI_AWSIZE,
    output wire [1:0]  M_AXI_AWBURST,
    output wire [3:0]  M_AXI_AWCACHE,
    output wire [2:0]  M_AXI_AWPROT,
    output wire        M_AXI_AWVALID,
    input  wire        M_AXI_AWREADY,
    output wire [63:0] M_AXI_WDATA,
    output wire [7:0]  M_AXI_WSTRB,
    output wire        M_AXI_WLAST,
    output wire        M_AXI_WVALID,
    input  wire        M_AXI_WREADY,
    input  wire [1:0]  M_AXI_BRESP,
    input  wire        M_AXI_BVALID,
    output wire        M_AXI_BREADY
);

    // =========================================================================
    // Top-level FSM
    // =========================================================================
    localparam ENG_IDLE  = 3'd0;
    localparam ENG_PIXEL = 3'd1;  // single pixel: trigger addr_calc directly
    localparam ENG_LINE  = 3'd2;  // line: run Bresenham, feed addr_calc
    localparam ENG_FLUSH = 3'd3;  // wait for burst writer to drain
    localparam ENG_DONE  = 3'd4;

    reg [2:0] eng_state;

    // =========================================================================
    // Bresenham core instance
    // =========================================================================
    reg        bres_start;
    wire       bres_pixel_valid;
    wire [10:0] bres_px, bres_py;
    wire [15:0] bres_pcolor;
    wire        bres_done;
    wire        bres_busy;

    bresenham_core u_bres (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (bres_start),
        .x0          (cmd_x0),
        .y0          (cmd_y0),
        .x1          (cmd_x1),
        .y1          (cmd_y1),
        .color       (cmd_color),
        .px          (bres_px),
        .py          (bres_py),
        .pcolor      (bres_pcolor),
        .pixel_valid (bres_pixel_valid),
        .done        (bres_done),
        .busy        (bres_busy)
    );

    // =========================================================================
    // Pixel address calculator instance
    // =========================================================================
    // For pixel-plot: we drive addr_calc directly from cmd registers
    // For line draw:  we drive addr_calc from Bresenham outputs
    reg        ac_in_valid;
    reg [10:0] ac_px, ac_py;
    reg [15:0] ac_color;

    wire        ac_out_valid;
    wire [31:0] ac_addr;
    wire [63:0] ac_data;
    wire [7:0]  ac_strb;

    pixel_addr_calc u_addr_calc (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (ac_in_valid),
        .px        (ac_px),
        .py        (ac_py),
        .color     (ac_color),
        .fb_base   (cmd_fb_base),
        .fb_stride (cmd_fb_stride),
        .out_valid (ac_out_valid),
        .pixel_addr(ac_addr),
        .pixel_data(ac_data),
        .pixel_strb(ac_strb)
    );

    // =========================================================================
    // AXI4 burst writer instance
    // =========================================================================
    wire        bw_pix_ready;
    wire        bw_busy;
    reg         bw_flush;

    axi4_burst_writer u_burst_wr (
        .clk          (clk),
        .rst_n        (rst_n),
        // Pixel FIFO side
        .pix_valid    (ac_out_valid),
        .pix_addr     (ac_addr),
        .pix_data     (ac_data),
        .pix_strb     (ac_strb),
        .pix_ready    (bw_pix_ready),
        .flush_req    (bw_flush),
        // AXI4 master
        .M_AXI_AWADDR (M_AXI_AWADDR),
        .M_AXI_AWLEN  (M_AXI_AWLEN),
        .M_AXI_AWSIZE (M_AXI_AWSIZE),
        .M_AXI_AWBURST(M_AXI_AWBURST),
        .M_AXI_AWCACHE(M_AXI_AWCACHE),
        .M_AXI_AWPROT (M_AXI_AWPROT),
        .M_AXI_AWVALID(M_AXI_AWVALID),
        .M_AXI_AWREADY(M_AXI_AWREADY),
        .M_AXI_WDATA  (M_AXI_WDATA),
        .M_AXI_WSTRB  (M_AXI_WSTRB),
        .M_AXI_WLAST  (M_AXI_WLAST),
        .M_AXI_WVALID (M_AXI_WVALID),
        .M_AXI_WREADY (M_AXI_WREADY),
        .M_AXI_BRESP  (M_AXI_BRESP),
        .M_AXI_BVALID (M_AXI_BVALID),
        .M_AXI_BREADY (M_AXI_BREADY),
        .busy         (bw_busy),
        .write_error  ()  // tie off for now; connect to STATUS reg extension
    );

    // =========================================================================
    // Top FSM — orchestrates pixel-plot vs line commands
    // =========================================================================
    assign engine_busy = (eng_state != ENG_IDLE);

    always @(posedge clk) begin
        if (!rst_n) begin
            eng_state   <= ENG_IDLE;
            bres_start  <= 1'b0;
            ac_in_valid <= 1'b0;
            bw_flush    <= 1'b0;
            engine_done <= 1'b0;
        end else begin
            bres_start  <= 1'b0;
            engine_done <= 1'b0;

            // Default: don't drive addr_calc from FSM
            ac_in_valid <= 1'b0;

            case (eng_state)

                ENG_IDLE: begin
                    bw_flush <= 1'b0;
                    if (cmd_valid) begin
                        case (cmd_type)
                            2'd0: eng_state <= ENG_PIXEL; // single pixel
                            2'd1: begin
                                bres_start  <= 1'b1;     // start Bresenham
                                eng_state   <= ENG_LINE;
                            end
                            default: eng_state <= ENG_IDLE;
                        endcase
                    end
                end

                // --------------------------------------------------------------
                // Single pixel: inject one beat into addr_calc
                // --------------------------------------------------------------
                ENG_PIXEL: begin
                    ac_in_valid <= 1'b1;
                    ac_px       <= cmd_x0;
                    ac_py       <= cmd_y0;
                    ac_color    <= cmd_color;
                    bw_flush    <= 1'b1;   // force burst even for 1 pixel
                    eng_state   <= ENG_FLUSH;
                end

                // --------------------------------------------------------------
                // Line: relay Bresenham output to addr_calc
                // --------------------------------------------------------------
                ENG_LINE: begin
                    // Relay Bresenham pixel outputs to address calculator
                    ac_in_valid <= bres_pixel_valid;
                    ac_px       <= bres_px;
                    ac_py       <= bres_py;
                    ac_color    <= bres_pcolor;

                    if (bres_done) begin
                        bw_flush  <= 1'b1;  // flush remaining pixels in FIFO
                        eng_state <= ENG_FLUSH;
                    end
                end

                // --------------------------------------------------------------
                // Wait for burst writer to finish draining
                // --------------------------------------------------------------
                ENG_FLUSH: begin
                    bw_flush <= 1'b1;
                    if (!bw_busy) begin
                        bw_flush  <= 1'b0;
                        eng_state <= ENG_DONE;
                    end
                end

                // --------------------------------------------------------------
                ENG_DONE: begin
                    engine_done <= 1'b1;
                    eng_state   <= ENG_IDLE;
                end

                default: eng_state <= ENG_IDLE;

            endcase
        end
    end

endmodule
