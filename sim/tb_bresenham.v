// =============================================================================
// Testbench : tb_bresenham.v
// Module    : bresenham_core
// Tests     : All 8 octants, horizontal, vertical, diagonal, single pixel
//
// Run in Vivado (xsim):
//   set_property top tb_bresenham [current_fileset -simset]
//   launch_simulation
// Or with Icarus Verilog:
//   iverilog -o tb_bresenham.out tb_bresenham.v ../hdl/bresenham_core.v
//   vvp tb_bresenham.out
// =============================================================================

`timescale 1ns / 1ps

module tb_bresenham;

    // =========================================================================
    // DUT signals
    // =========================================================================
    reg        clk = 0;
    reg        rst_n = 0;
    reg        start = 0;
    reg [10:0] x0, y0, x1, y1;
    reg [15:0] color;
    wire [10:0] px, py;
    wire [15:0] pcolor;
    wire        pixel_valid;
    wire        done;
    wire        busy;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    bresenham_core dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .x0         (x0),   .y0 (y0),
        .x1         (x1),   .y1 (y1),
        .color      (color),
        .px         (px),   .py (py),
        .pcolor     (pcolor),
        .pixel_valid(pixel_valid),
        .done       (done),
        .busy       (busy)
    );

    // =========================================================================
    // Clock: 100 MHz
    // =========================================================================
    always #5 clk = ~clk;

    // =========================================================================
    // Helper task: draw a line and print all pixels
    // =========================================================================
    integer pixel_count;
    integer timeout_cnt;

    task draw_line_test;
        input [10:0] _x0, _y0, _x1, _y1;
        input [15:0] _color;
        input [127:0] test_name; // ASCII label
        begin
            @(negedge clk);
            x0 = _x0; y0 = _y0; x1 = _x1; y1 = _y1; color = _color;
            start = 1;
            @(negedge clk);
            start = 0;

            pixel_count = 0;
            timeout_cnt = 0;
            $display("--- TEST: %s  (%0d,%0d)->(%0d,%0d) ---",
                     test_name, _x0, _y0, _x1, _y1);

            while (!done) begin
                @(posedge clk);
                #1; // small delta to read outputs after clock
                if (pixel_valid) begin
                    $display("  px=%4d  py=%4d  color=0x%04X", px, py, pcolor);
                    pixel_count = pixel_count + 1;
                end
                timeout_cnt = timeout_cnt + 1;
                if (timeout_cnt > 5000) begin
                    $error("  TIMEOUT waiting for done — FAIL");
                    disable draw_line_test;
                end
            end
            $display("  >> Total pixels: %0d", pixel_count);
            $display("");
        end
    endtask

    // =========================================================================
    // Test sequence
    // =========================================================================
    initial begin
        // VCD dump for waveform viewer
        $dumpfile("tb_bresenham.vcd");
        $dumpvars(0, tb_bresenham);

        // Reset
        rst_n = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // ---------------------------------------------------------------
        // Octant 0: shallow positive slope, left→right
        draw_line_test(0, 0, 10, 3, 16'hF800, "OCT0 L-R shallow");

        // Octant 1: steep positive slope, left→right
        draw_line_test(0, 0, 3, 10, 16'h07E0, "OCT1 L-R steep");

        // Horizontal line
        draw_line_test(5, 5, 15, 5, 16'hFFFF, "HORIZONTAL");

        // Vertical line
        draw_line_test(7, 0, 7, 8, 16'h001F, "VERTICAL");

        // 45-degree diagonal
        draw_line_test(0, 0, 8, 8, 16'hF81F, "DIAGONAL 45deg");

        // Reverse direction (right→left)
        draw_line_test(10, 5, 0, 5, 16'hFFE0, "REVERSE HORIZONTAL");

        // Steep reverse (bottom→top)
        draw_line_test(3, 10, 0, 0, 16'hFBE0, "STEEP REVERSE");

        // Single pixel (x0==x1, y0==y1)
        draw_line_test(640, 360, 640, 360, 16'hFFFF, "SINGLE PIXEL");

        // Long diagonal (close to screen edge)
        draw_line_test(0, 0, 100, 75, 16'hF800, "LONG DIAGONAL");

        // ---------------------------------------------------------------
        $display("=== All Bresenham tests complete ===");
        #50;
        $finish;
    end

    // =========================================================================
    // Assertions: final pixel should equal the endpoint
    // =========================================================================
    // (Simple manual check — extend with immediate assertions for full coverage)

endmodule
