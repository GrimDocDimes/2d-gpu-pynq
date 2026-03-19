// =============================================================================
// Module     : pixel_addr_calc.v
// Project    : 2D GPU Accelerator — PYNQ-Z2
// Description: 2-stage registered pipeline.
//              Stage 1: row_offset = py * stride  (uses multiplier/DSP)
//              Stage 2: byte_addr, 64-bit beat packing, byte enables
//
//   Input  : pixel (px, py, color, valid) + fb_base, fb_stride
//   Output : (addr, data, strb, valid) to AXI4 burst writer FIFO
//
// Latency  : 2 clock cycles
// Throughput: 1 pixel per clock (fully pipelined)
// =============================================================================

`timescale 1ns / 1ps

module pixel_addr_calc (
    input  wire        clk,
    input  wire        rst_n,

    // Pixel stream in
    input  wire        in_valid,
    input  wire [10:0] px,
    input  wire [10:0] py,
    input  wire [15:0] color,

    // Framebuffer configuration
    input  wire [31:0] fb_base,    // physical DDR base address
    input  wire [15:0] fb_stride,  // bytes per row (default: 1280*2 = 2560)

    // Output to burst-writer FIFO
    output reg         out_valid,
    output reg  [31:0] pixel_addr, // 8-byte aligned DDR address
    output reg  [63:0] pixel_data, // RGB565 packed into 64-bit beat
    output reg  [7:0]  pixel_strb  // byte enables (2 bytes active)
);

    // =========================================================================
    // Pipeline stage 1 registers
    // =========================================================================
    reg        s1_valid;
    reg [31:0] s1_row_offset;    // py * stride
    reg [10:0] s1_px;
    reg [15:0] s1_color;

    // =========================================================================
    // Stage 0 → Stage 1: row offset multiplication
    // Vivado will infer a DSP48 for 11×16-bit multiply.
    // =========================================================================
    wire [31:0] row_product = {21'b0, py} * {16'b0, fb_stride};

    always @(posedge clk) begin
        if (!rst_n) begin
            s1_valid <= 1'b0;
        end else begin
            s1_valid      <= in_valid;
            s1_row_offset <= row_product;
            s1_px         <= px;
            s1_color      <= color;
        end
    end

    // =========================================================================
    // Stage 1 → Stage 2 (output): byte addressing + beat packing
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
        end else begin
            out_valid <= s1_valid;

            if (s1_valid) begin
                // Byte offset of the pixel from start of framebuffer
                // px * 2 = left-shift by 1 (RGB565, 2 bytes per pixel)
                automatic reg [31:0] byte_offset;
                automatic reg [2:0]  beat_byte;  // which byte within 8-byte beat
                automatic reg [31:0] aligned_addr;

                byte_offset  = s1_row_offset + {21'b0, s1_px, 1'b0};
                beat_byte    = byte_offset[2:0];              // 0..7 within 64-bit beat
                aligned_addr = fb_base + (byte_offset & ~32'h7); // 8-byte align

                pixel_addr <= aligned_addr;

                // Pack 16-bit color into correct byte lane of the 64-bit beat
                // Using dynamic shift — Vivado synthesises well with barrel shifter
                pixel_data <= {48'b0, s1_color} << {beat_byte, 3'b000};

                // Two consecutive byte-enables for the 2-byte pixel
                pixel_strb <= 8'b0000_0011 << beat_byte;
            end
        end
    end

endmodule
