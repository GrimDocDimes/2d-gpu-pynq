// =============================================================================
// Testbench : tb_pixel_addr_calc.v
// Module    : pixel_addr_calc
// Tests     : Address calculation, byte enables, edge pixels
//
// Expected:  addr = fb_base + (py*stride + px*2) aligned to 8 bytes
//            strb marks exactly 2 byte-enable bits at correct lane
//
// Run with Icarus Verilog:
//   iverilog -o tb_pac.out tb_pixel_addr_calc.v ../hdl/pixel_addr_calc.v
//   vvp tb_pac.out
// =============================================================================

`timescale 1ns / 1ps

module tb_pixel_addr_calc;

    reg        clk = 0;
    reg        rst_n = 0;
    reg        in_valid;
    reg [10:0] px, py;
    reg [15:0] color;
    reg [31:0] fb_base;
    reg [15:0] fb_stride;

    wire        out_valid;
    wire [31:0] pixel_addr;
    wire [63:0] pixel_data;
    wire [7:0]  pixel_strb;

    pixel_addr_calc dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .px        (px),
        .py        (py),
        .color     (color),
        .fb_base   (fb_base),
        .fb_stride (fb_stride),
        .out_valid (out_valid),
        .pixel_addr(pixel_addr),
        .pixel_data(pixel_data),
        .pixel_strb(pixel_strb)
    );

    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Helper task: send pixel, wait 2 cycles for output, check result
    // -------------------------------------------------------------------------
    task check_pixel;
        input [10:0] _px, _py;
        input [15:0] _color;
        input [31:0] expected_addr;
        input [7:0]  expected_strb;
        begin
            @(negedge clk);
            px       = _px;
            py       = _py;
            color    = _color;
            in_valid = 1;
            @(negedge clk);
            in_valid = 0;

            // Wait 2 pipeline cycles
            repeat(2) @(posedge clk);
            #1;

            $display("px=%4d py=%4d | addr=0x%08X (exp 0x%08X) %s | strb=0x%02X (exp 0x%02X) %s",
                _px, _py,
                pixel_addr, expected_addr,
                (pixel_addr == expected_addr) ? "OK" : "FAIL",
                pixel_strb,  expected_strb,
                (pixel_strb  == expected_strb)  ? "OK" : "FAIL");

            if (pixel_addr !== expected_addr)
                $error("  ADDRESS MISMATCH at pixel (%0d,%0d)", _px, _py);
            if (pixel_strb !== expected_strb)
                $error("  STROBE MISMATCH at pixel (%0d,%0d)", _px, _py);
        end
    endtask

    initial begin
        $dumpfile("tb_pac.vcd");
        $dumpvars(0, tb_pixel_addr_calc);

        fb_base   = 32'h1000_0000;
        fb_stride = 16'd2560;   // 1280 * 2 bytes
        in_valid  = 0;

        rst_n = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        $display("=== pixel_addr_calc testbench ===");
        $display("fb_base=0x%08X  stride=%0d", fb_base, fb_stride);
        $display("");

        // Pixel (0,0): byte_offset=0, addr=0x1000_0000, strb=0b00000011
        check_pixel(0, 0, 16'hF800, 32'h1000_0000, 8'b0000_0011);

        // Pixel (1,0): byte_offset=2, addr=0x1000_0000 (same 8-byte beat), strb=0b00001100
        check_pixel(1, 0, 16'h07E0, 32'h1000_0000, 8'b0000_1100);

        // Pixel (4,0): byte_offset=8, addr=0x1000_0008, strb=0b00000011
        check_pixel(4, 0, 16'h001F, 32'h1000_0008, 8'b0000_0011);

        // Pixel (0,1): byte_offset=2560=0xA00, addr=0x1000_0A00 (2560 is 8-byte aligned), strb=0b00000011
        check_pixel(0, 1, 16'hFFFF, 32'h1000_0A00, 8'b0000_0011);

        // Pixel (1279,719): last pixel
        // byte_offset = 719*2560 + 1279*2 = 1840640 + 2558 = 1843198 = 0x1C1FFE
        // aligned    = 0x1C1FF8
        // beat_byte  = 6  → strb = 0b11000000
        check_pixel(1279, 719, 16'hF81F, 32'h1000_0000 + 32'h1C1FF8, 8'b1100_0000);

        // Pixel (639,360): middle
        // byte_offset = 360*2560 + 639*2 = 921600 + 1278 = 922878 = 0xE157E
        // aligned    = 0xE1578
        // beat_byte  = 6  → strb = 11000000
        check_pixel(639, 360, 16'hABCD, 32'h1000_0000 + 32'h000E1578, 8'b1100_0000);

        $display("");
        $display("=== Tests complete ===");
        #50;
        $finish;
    end

endmodule
