// =============================================================================
// Testbench : tb_drawing_engine.v
// Module    : drawing_engine (top-level)
// Tests     : Single pixel plot + 3-pixel line via AXI4 memory model
//
// Uses a simple behavioral AXI4 slave that accepts writes and stores to
// a local memory array. After test, reads back pixel data and verifies.
// =============================================================================

`timescale 1ns / 1ps

module tb_drawing_engine;

    // =========================================================================
    // Clocks and reset
    // =========================================================================
    reg clk   = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;  // 100 MHz

    // =========================================================================
    // DUT connections
    // =========================================================================
    reg        cmd_valid;
    reg [1:0]  cmd_type;
    reg [10:0] cmd_x0, cmd_y0, cmd_x1, cmd_y1;
    reg [15:0] cmd_color;
    reg [31:0] cmd_fb_base   = 32'h1000_0000;
    reg [15:0] cmd_fb_stride = 16'd2560;

    wire        engine_busy;
    wire        engine_done;

    // AXI4 Master Write
    wire [31:0] AWADDR;
    wire [7:0]  AWLEN;
    wire [2:0]  AWSIZE;
    wire [1:0]  AWBURST;
    wire [3:0]  AWCACHE;
    wire [2:0]  AWPROT;
    wire        AWVALID;
    reg         AWREADY;
    wire [63:0] WDATA;
    wire [7:0]  WSTRB;
    wire        WLAST;
    wire        WVALID;
    reg         WREADY;
    reg  [1:0]  BRESP = 2'b00;
    reg         BVALID;
    wire        BREADY;

    drawing_engine dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .cmd_valid    (cmd_valid),
        .cmd_type     (cmd_type),
        .cmd_x0       (cmd_x0), .cmd_y0(cmd_y0),
        .cmd_x1       (cmd_x1), .cmd_y1(cmd_y1),
        .cmd_color    (cmd_color),
        .cmd_fb_base  (cmd_fb_base),
        .cmd_fb_stride(cmd_fb_stride),
        .engine_busy  (engine_busy),
        .engine_done  (engine_done),
        .M_AXI_AWADDR (AWADDR),
        .M_AXI_AWLEN  (AWLEN),
        .M_AXI_AWSIZE (AWSIZE),
        .M_AXI_AWBURST(AWBURST),
        .M_AXI_AWCACHE(AWCACHE),
        .M_AXI_AWPROT (AWPROT),
        .M_AXI_AWVALID(AWVALID),
        .M_AXI_AWREADY(AWREADY),
        .M_AXI_WDATA  (WDATA),
        .M_AXI_WSTRB  (WSTRB),
        .M_AXI_WLAST  (WLAST),
        .M_AXI_WVALID (WVALID),
        .M_AXI_WREADY (WREADY),
        .M_AXI_BRESP  (BRESP),
        .M_AXI_BVALID (BVALID),
        .M_AXI_BREADY (BREADY)
    );

    // =========================================================================
    // Behavioral AXI4 Slave Memory Model
    // Latency: AWREADY=1 cycle, WREADY always=1, BVALID after WLAST
    // =========================================================================
    reg [7:0] mem [0:4*1024*1024-1];  // 4 MB behavioral memory
    reg [31:0] burst_addr;
    integer i;

    initial begin
        // Zero-init memory
        for (i = 0; i < 4*1024*1024; i = i+1) mem[i] = 8'hFF;
        AWREADY = 0;
        WREADY  = 1;   // always ready to accept data
        BVALID  = 0;
    end

    // Accept write address with 1-cycle latency
    always @(posedge clk) begin
        if (AWVALID && !AWREADY) begin
            AWREADY    <= 1'b1;
            burst_addr <= AWADDR - 32'h1000_0000; // offset from base
        end else begin
            AWREADY <= 1'b0;
        end
    end

    // Accept write data and store to memory
    always @(posedge clk) begin
        if (WVALID && WREADY) begin
            // Write bytes individually using byte enables
            if (WSTRB[0]) mem[burst_addr+0] <= WDATA[7:0];
            if (WSTRB[1]) mem[burst_addr+1] <= WDATA[15:8];
            if (WSTRB[2]) mem[burst_addr+2] <= WDATA[23:16];
            if (WSTRB[3]) mem[burst_addr+3] <= WDATA[31:24];
            if (WSTRB[4]) mem[burst_addr+4] <= WDATA[39:32];
            if (WSTRB[5]) mem[burst_addr+5] <= WDATA[47:40];
            if (WSTRB[6]) mem[burst_addr+6] <= WDATA[55:48];
            if (WSTRB[7]) mem[burst_addr+7] <= WDATA[63:56];
            burst_addr <= burst_addr + 8;

            if (WLAST) begin
                BVALID <= 1'b1;
                BRESP  <= 2'b00; // OKAY
            end
        end
        if (BVALID && BREADY) BVALID <= 1'b0;
    end

    // =========================================================================
    // Pixel read helper function
    // =========================================================================
    function [15:0] read_pixel;
        input [10:0] _px, _py;
        reg [31:0] byte_off;
        begin
            byte_off   = _py * 2560 + _px * 2;
            read_pixel = {mem[byte_off+1], mem[byte_off]};
        end
    endfunction

    // =========================================================================
    // Test stimulus
    // =========================================================================
    task send_cmd;
        input [1:0]  _type;
        input [10:0] _x0, _y0, _x1, _y1;
        input [15:0] _color;
        begin
            @(negedge clk);
            cmd_type  = _type;
            cmd_x0    = _x0; cmd_y0 = _y0;
            cmd_x1    = _x1; cmd_y1 = _y1;
            cmd_color = _color;
            cmd_valid = 1;
            @(negedge clk);
            cmd_valid = 0;
            // Wait for done
            wait(engine_done);
            @(posedge clk); #1;
        end
    endtask

    initial begin
        $dumpfile("tb_engine.vcd");
        $dumpvars(0, tb_drawing_engine);

        cmd_valid = 0;
        rst_n = 0; repeat(5) @(posedge clk);
        rst_n = 1; repeat(3) @(posedge clk);

        // ---------------------------------------------------------------
        // Test 1: Single pixel at (10, 5) with color RED (0xF800)
        $display("--- Test 1: Single Pixel (10,5) RED ---");
        send_cmd(2'd0, 10, 5, 10, 5, 16'hF800);
        #1;
        if (read_pixel(10, 5) === 16'hF800)
            $display("  PASS: pixel(10,5) = 0x%04X", read_pixel(10,5));
        else
            $error("  FAIL: pixel(10,5) = 0x%04X (expected 0xF800)", read_pixel(10,5));

        // ---------------------------------------------------------------
        // Test 2: Horizontal line (0,0)→(3,0) GREEN (0x07E0)
        $display("--- Test 2: Horizontal Line (0,0)->(3,0) GREEN ---");
        send_cmd(2'd1, 0, 0, 3, 0, 16'h07E0);
        #1;
        begin : verify_hline
            integer j;
            for (j = 0; j <= 3; j = j+1) begin
                if (read_pixel(j, 0) === 16'h07E0)
                    $display("  PASS: pixel(%0d,0) = 0x%04X", j, read_pixel(j,0));
                else
                    $error("  FAIL: pixel(%0d,0) = 0x%04X (expected 0x07E0)", j, read_pixel(j,0));
            end
        end

        // ---------------------------------------------------------------
        // Test 3: Diagonal line (0,0)→(4,4) WHITE (0xFFFF)
        $display("--- Test 3: Diagonal Line (0,0)->(4,4) WHITE ---");
        send_cmd(2'd1, 0, 0, 4, 4, 16'hFFFF);
        #1;
        begin : verify_diag
            integer k;
            for (k = 0; k <= 4; k = k+1) begin
                if (read_pixel(k, k) === 16'hFFFF)
                    $display("  PASS: pixel(%0d,%0d) = 0x%04X", k, k, read_pixel(k,k));
                else
                    $error("  FAIL: pixel(%0d,%0d) = 0x%04X (expected 0xFFFF)", k, k, read_pixel(k,k));
            end
        end

        $display("=== drawing_engine testbench complete ===");
        #200;
        $finish;
    end

endmodule
