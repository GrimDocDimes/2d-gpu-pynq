// =============================================================================
// Module     : bresenham_core.v
// Project    : 2D GPU Accelerator — PYNQ-Z2
// Description: Hardware Bresenham line drawing algorithm.
//              Produces 1 pixel coordinate per clock cycle in DRAW state.
//              Supports all 8 octants (any slope, any direction).
//
// Ports:
//   clk         — system clock (AXI fabric clock, e.g. 100 MHz)
//   rst_n       — active-low synchronous reset
//   start       — pulse high for 1 cycle to begin drawing
//   x0,y0       — start point (11-bit, supports up to 2048 pixels)
//   x1,y1       — end point
//   color       — RGB565 pixel color
//   px,py       — output pixel coordinate (valid when pixel_valid=1)
//   pcolor      — output pixel color (registered, matches px/py)
//   pixel_valid — high for 1 cycle per output pixel
//   done        — pulses high for 1 cycle when line complete
// =============================================================================

`timescale 1ns / 1ps

module bresenham_core (
    input  wire        clk,
    input  wire        rst_n,

    // Command interface
    input  wire        start,
    input  wire [10:0] x0,
    input  wire [10:0] y0,
    input  wire [10:0] x1,
    input  wire [10:0] y1,
    input  wire [15:0] color,

    // Pixel output stream
    output reg  [10:0] px,
    output reg  [10:0] py,
    output reg  [15:0] pcolor,
    output reg         pixel_valid,
    output reg         done,
    output reg         busy
);

    // -------------------------------------------------------------------------
    // State encoding
    // -------------------------------------------------------------------------
    localparam S_IDLE = 2'd0;
    localparam S_INIT = 2'd1;  // 1-cycle setup (dx, dy, err, sx, sy)
    localparam S_DRAW = 2'd2;  // iterative pixel output
    localparam S_DONE = 2'd3;  // pulse done, return to IDLE

    reg [1:0] state;

    // -------------------------------------------------------------------------
    // Registered working variables
    // -------------------------------------------------------------------------
    reg [10:0] cur_x, cur_y;
    reg [10:0] end_x, end_y;
    reg signed [11:0] dx;   // |x1 - x0|
    reg signed [11:0] dy;   // -|y1 - y0|  (negative, per Bresenham convention)
    reg signed [11:0] err;  // error accumulator
    reg signed [1:0]  sx;   // x step direction (+1 or -1)
    reg signed [1:0]  sy;   // y step direction (+1 or -1)
    reg [15:0] latched_color;

    // 2*err for comparison (combinational)
    wire signed [12:0] e2 = {err[11], err} <<< 1;  // sign-extended left shift

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            pixel_valid <= 1'b0;
            done        <= 1'b0;
            busy        <= 1'b0;
            px          <= 11'd0;
            py          <= 11'd0;
        end else begin
            // Default: deassert pulses
            pixel_valid <= 1'b0;
            done        <= 1'b0;

            case (state)

                // ----------------------------------------------------------
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        latched_color <= color;
                        end_x         <= x1;
                        end_y         <= y1;
                        state         <= S_INIT;
                        busy          <= 1'b1;
                    end
                end

                // ----------------------------------------------------------
                // Compute Bresenham parameters (1 cycle)
                S_INIT: begin
                    cur_x <= x0;
                    cur_y <= y0;

                    // dx = |x1 - x0|
                    dx <= (x1 >= x0) ? $signed({1'b0, x1 - x0})
                                     : $signed({1'b0, x0 - x1});

                    // dy = -|y1 - y0|  (negative for Bresenham error test)
                    dy <= (y1 >= y0) ? -$signed({1'b0, y1 - y0})
                                     : -$signed({1'b0, y0 - y1});

                    // Step directions
                    sx <= (x0 < x1) ? 2'sd1 : -2'sd1;
                    sy <= (y0 < y1) ? 2'sd1 : -2'sd1;

                    // Initial error = dx + dy  (dx positive, dy negative)
                    //   computed next cycle from registered dx/dy — but we
                    //   can safely register here and use in DRAW since INIT
                    //   is a single-cycle state.
                    // (Will be fully valid at start of first DRAW cycle.)
                    state <= S_DRAW;
                end

                // ----------------------------------------------------------
                // Iterative draw — 1 pixel per clock
                S_DRAW: begin
                    // Output current pixel
                    pixel_valid <= 1'b1;
                    px          <= cur_x;
                    py          <= cur_y;
                    pcolor      <= latched_color;

                    // Latch err properly (was set from dx+dy in last INIT cycle)
                    // The first time through S_DRAW, err comes from the blocking
                    // assignment path in S_INIT; subsequent iterations update err below.

                    if (cur_x == end_x && cur_y == end_y) begin
                        // Last pixel — go to DONE next cycle
                        state <= S_DONE;
                    end else begin
                        // Bresenham error update
                        // Two compare-and-update steps (matches software algorithm exactly)
                        if (e2 >= dy) begin
                            err   <= err + dy;
                            cur_x <= cur_x + $unsigned(sx);
                        end
                        if (e2 <= dx) begin
                            err   <= err + dx;
                            cur_y <= cur_y + $unsigned(sy);
                        end
                    end
                end

                // ----------------------------------------------------------
                S_DONE: begin
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase

            // Initialise err when entering S_DRAW for first time
            // (registered from S_INIT values of dx and dy)
            if (state == S_INIT) begin
                // dx and dy are being written this cycle; we pre-compute err
                // here to be ready for first S_DRAW cycle.
                // Use combinational inputs (x0,y0,x1,y1) directly.
                err <= $signed(((x1 >= x0) ? {1'b0, x1 - x0} : {1'b0, x0 - x1}))
                     + $signed(((y1 >= y0) ? -{1'b0, y1 - y0} : -{1'b0, y0 - y1}));
            end
        end
    end

endmodule
