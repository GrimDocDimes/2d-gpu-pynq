// =============================================================================
// Module     : axi4_burst_writer.v
// Project    : 2D GPU Accelerator — PYNQ-Z2
// Description: AXI4 Master burst write engine.
//              Collects pixels from an internal FIFO and fires 256-beat
//              INCR bursts to DDR through the Zynq HP0 slave port.
//
//   - Data width : 64-bit (4 pixels of RGB565 per beat)
//   - Max burst  : 256 beats (AXI4 maximum)
//   - Burst fires when FIFO has >= BURST_LEN entries OR flush_req is asserted
//   - Tracks current write address; increments by 8 bytes per beat
//
// FIFO interface is direct (no async FIFO needed if single clock domain).
// Use async_fifo wrapper if pixel_addr_calc runs on a different clock.
// =============================================================================

`timescale 1ns / 1ps

module axi4_burst_writer #(
    parameter BURST_LEN  = 256,   // beats per AXI burst (1–256)
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 64     // must match HP0 configuration
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // -------------------------------------------------------------------------
    // Pixel input interface (from pixel_addr_calc)
    // -------------------------------------------------------------------------
    input  wire                  pix_valid,
    input  wire [ADDR_WIDTH-1:0] pix_addr,   // 8-byte aligned DDR address
    input  wire [DATA_WIDTH-1:0] pix_data,   // pixel data packed into 64-bit
    input  wire [7:0]            pix_strb,   // byte enables
    output wire                  pix_ready,  // back-pressure to pixel source

    // Force a partial burst (assert at end-of-line for remaining pixels)
    input  wire                  flush_req,

    // -------------------------------------------------------------------------
    // AXI4 Master Write — Address channel (AW)
    // -------------------------------------------------------------------------
    output reg  [ADDR_WIDTH-1:0] M_AXI_AWADDR,
    output reg  [7:0]            M_AXI_AWLEN,    // burst length - 1
    output reg  [2:0]            M_AXI_AWSIZE,   // 3 = 8 bytes/beat
    output reg  [1:0]            M_AXI_AWBURST,  // 01 = INCR
    output reg  [3:0]            M_AXI_AWCACHE,  // 0011 = bufferable
    output reg  [2:0]            M_AXI_AWPROT,
    output reg                   M_AXI_AWVALID,
    input  wire                  M_AXI_AWREADY,

    // -------------------------------------------------------------------------
    // AXI4 Master Write — Data channel (W)
    // -------------------------------------------------------------------------
    output reg  [DATA_WIDTH-1:0] M_AXI_WDATA,
    output reg  [7:0]            M_AXI_WSTRB,
    output reg                   M_AXI_WLAST,
    output reg                   M_AXI_WVALID,
    input  wire                  M_AXI_WREADY,

    // -------------------------------------------------------------------------
    // AXI4 Master Write — Response channel (B)
    // -------------------------------------------------------------------------
    input  wire [1:0]            M_AXI_BRESP,
    input  wire                  M_AXI_BVALID,
    output reg                   M_AXI_BREADY,

    // Status
    output wire                  busy,
    output reg                   write_error      // latches on BRESP != OKAY
);

    // =========================================================================
    // Internal FIFO (synchronous, FWFT mode)
    // Stores  (addr:32, data:64, strb:8) = 104 bits per entry
    // Depth = BURST_LEN * 2 so we can fill next burst while sending current
    // =========================================================================
    localparam FIFO_DEPTH = BURST_LEN * 2;
    localparam FIFO_WIDTH = ADDR_WIDTH + DATA_WIDTH + 8; // 104

    reg [FIFO_WIDTH-1:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [$clog2(FIFO_DEPTH):0] fifo_wr_ptr, fifo_rd_ptr;
    wire [$clog2(FIFO_DEPTH):0] fifo_count = fifo_wr_ptr - fifo_rd_ptr;
    wire fifo_empty = (fifo_count == 0);
    wire fifo_full  = (fifo_count == FIFO_DEPTH);

    assign pix_ready = !fifo_full;

    // FIFO write (from pixel_addr_calc)
    always @(posedge clk) begin
        if (!rst_n) begin
            fifo_wr_ptr <= 0;
        end else if (pix_valid && !fifo_full) begin
            fifo_mem[fifo_wr_ptr[$clog2(FIFO_DEPTH)-1:0]] <=
                {pix_addr, pix_data, pix_strb};
            fifo_wr_ptr <= fifo_wr_ptr + 1;
        end
    end

    // =========================================================================
    // AXI4 Burst Writer FSM
    // =========================================================================
    localparam ST_IDLE    = 3'd0;
    localparam ST_AW      = 3'd1;   // Send write address
    localparam ST_WDATA   = 3'd2;   // Send write data beats
    localparam ST_BRESP   = 3'd3;   // Wait for write response
    localparam ST_FLUSH   = 3'd4;   // Partial burst on flush

    reg [2:0]  state;
    reg [8:0]  beat_cnt;     // counts 0..BURST_LEN-1 within a burst
    reg [8:0]  burst_beats;  // actual beats in this burst (may be < BURST_LEN on flush)
    reg [31:0] burst_base_addr;

    assign busy = (state != ST_IDLE);

    // Decide to start a burst
    wire start_burst = (!fifo_empty) &&
                       ((fifo_count >= BURST_LEN) || flush_req);

    // FIFO read port
    wire [FIFO_WIDTH-1:0] fifo_rdata = fifo_mem[fifo_rd_ptr[$clog2(FIFO_DEPTH)-1:0]];
    wire [ADDR_WIDTH-1:0] rd_addr    = fifo_rdata[FIFO_WIDTH-1 : DATA_WIDTH+8];
    wire [DATA_WIDTH-1:0] rd_data    = fifo_rdata[DATA_WIDTH+7 : 8];
    wire [7:0]            rd_strb    = fifo_rdata[7:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            fifo_rd_ptr    <= 0;
            M_AXI_AWVALID  <= 1'b0;
            M_AXI_WVALID   <= 1'b0;
            M_AXI_WLAST    <= 1'b0;
            M_AXI_BREADY   <= 1'b0;
            write_error    <= 1'b0;
            beat_cnt       <= 0;
        end else begin
            case (state)

                // ----------------------------------------------------------------
                ST_IDLE: begin
                    M_AXI_AWVALID <= 1'b0;
                    M_AXI_WVALID  <= 1'b0;
                    M_AXI_BREADY  <= 1'b0;
                    beat_cnt      <= 0;

                    if (start_burst) begin
                        // Capture burst size (may be partial on flush)
                        burst_beats     <= (fifo_count >= BURST_LEN) ?
                                           BURST_LEN : fifo_count[8:0];
                        burst_base_addr <= rd_addr; // address from first FIFO entry
                        state           <= ST_AW;
                    end
                end

                // ----------------------------------------------------------------
                ST_AW: begin
                    M_AXI_AWADDR  <= burst_base_addr;
                    M_AXI_AWLEN   <= burst_beats - 1; // 0-indexed
                    M_AXI_AWSIZE  <= 3'b011;          // 8 bytes
                    M_AXI_AWBURST <= 2'b01;           // INCR
                    M_AXI_AWCACHE <= 4'b0011;         // bufferable
                    M_AXI_AWPROT  <= 3'b010;          // non-secure data
                    M_AXI_AWVALID <= 1'b1;

                    if (M_AXI_AWREADY) begin
                        M_AXI_AWVALID <= 1'b0;
                        state         <= ST_WDATA;
                    end
                end

                // ----------------------------------------------------------------
                ST_WDATA: begin
                    if (!fifo_empty) begin
                        M_AXI_WVALID <= 1'b1;
                        M_AXI_WDATA  <= rd_data;
                        M_AXI_WSTRB  <= rd_strb;
                        M_AXI_WLAST  <= (beat_cnt == burst_beats - 1);

                        if (M_AXI_WREADY) begin
                            fifo_rd_ptr <= fifo_rd_ptr + 1;
                            beat_cnt    <= beat_cnt + 1;

                            if (beat_cnt == burst_beats - 1) begin
                                M_AXI_WVALID <= 1'b0;
                                M_AXI_WLAST  <= 1'b0;
                                state        <= ST_BRESP;
                            end
                        end
                    end else begin
                        M_AXI_WVALID <= 1'b0; // FIFO momentarily empty — insert bubble
                    end
                end

                // ----------------------------------------------------------------
                ST_BRESP: begin
                    M_AXI_BREADY <= 1'b1;
                    if (M_AXI_BVALID) begin
                        M_AXI_BREADY <= 1'b0;
                        if (M_AXI_BRESP != 2'b00)
                            write_error <= 1'b1;  // Latch error for PS to read
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;

            endcase
        end
    end

endmodule
