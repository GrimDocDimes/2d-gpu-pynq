# Architecture Overview — 2D GPU Accelerator for PYNQ-Z2

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          PYNQ-Z2 (Zynq XC7Z020)                │
│                                                                  │
│  ┌───────────────────────┐    ┌───────────────────────────────┐ │
│  │   ARM Cortex-A9 PS    │    │     PL (FPGA Fabric)          │ │
│  │                       │    │                               │ │
│  │  Python / Jupyter     │    │  ┌─────────────────────────┐  │ │
│  │  gpu_draw.py          │    │  │   gpu_ctrl_axi          │  │ │
│  │                       │    │  │   (AXI4-Lite slave)     │  │ │
│  │  AXI GP0 master  ─────┼────┼─▶│   8 × 32-bit registers  │  │ │
│  │  (control path)       │    │  │   START, STATUS, coords, │  │ │
│  │                       │    │  │   color, FB_BASE, IRQ    │  │ │
│  │  IRQ_F2P[0]  ◀────────┼────┼──│   irq (done pulse)      │  │ │
│  │                       │    │  └──────────┬──────────────┘  │ │
│  │                       │    │             │ cmd_valid        │ │
│  │                       │    │             │ cmd_x0/y0/x1/y1 │ │
│  │                       │    │             │ cmd_color        │ │
│  │                       │    │             ▼                  │ │
│  │                       │    │  ┌─────────────────────────┐  │ │
│  │                       │    │  │   drawing_engine        │  │ │
│  │                       │    │  │   (top-level FSM)       │  │ │
│  │                       │    │  │                         │  │ │
│  │                       │    │  │  ┌──────────────────┐   │  │ │
│  │                       │    │  │  │ bresenham_core   │   │  │ │
│  │                       │    │  │  │ 1 px/clk, 8 oct  │   │  │ │
│  │                       │    │  │  └────────┬─────────┘   │  │ │
│  │                       │    │  │           │px, py, valid │  │ │
│  │                       │    │  │           ▼              │  │ │
│  │                       │    │  │  ┌──────────────────┐   │  │ │
│  │                       │    │  │  │ pixel_addr_calc  │   │  │ │
│  │                       │    │  │  │ 2-stage pipeline  │   │  │ │
│  │                       │    │  │  │ px×2 + py×stride │   │  │ │
│  │                       │    │  │  │ + fb_base align  │   │  │ │
│  │                       │    │  │  └────────┬─────────┘   │  │ │
│  │                       │    │  │           │addr,data,strb│  │ │
│  │                       │    │  │           ▼              │  │ │
│  │                       │    │  │  ┌──────────────────┐   │  │ │
│  │                       │    │  │  │ axi4_burst_writer│   │  │ │
│  │                       │    │  │  │ FIFO (512 entries)│  │  │ │
│  │                       │    │  │  │ 256-beat INCR    │   │  │ │
│  │                       │    │  │  │ 64-bit wide      │   │  │ │
│  │                       │    │  └──┴────────┬─────────┴───┘  │ │
│  │                       │    │              │ AXI4 master     │ │
│  │  HP0 slave  ◀─────────┼────┼─────────────┘ (write-only)   │ │
│  │  DDR write path       │    │                               │ │
│  │                       │    │  ┌─────────────────────────┐  │ │
│  │  HP1 slave  ◀─────────┼────┼──│   AXI VDMA              │  │ │
│  │  DDR read path        │    │  │   MM2S read channel      │  │ │
│  │                       │    │  │   reads RGB565 framebuf  │  │ │
│  └───────────────────────┘    │  └──────────┬──────────────┘  │ │
│                               │             │ AXI4-Stream     │ │
│                               │             ▼                  │ │
│                               │  ┌─────────────────────────┐  │ │
│                               │  │   rgb2dvi (HDMI TX)     │  │ │
│                               │  │   TMDS serializer       │  │ │
│                               │  └─────────────────────────┘  │ │
│                               └───────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                                        │ HDMI
                                        ▼
                                  [ HDMI Display ]
```

---

## Module Descriptions

### `gpu_ctrl_axi.v`
**AXI4-Lite slave register file**

The ARM PS writes draw commands here via the GP0 AXI port. Contains 8 × 32-bit registers:

| Offset | Register   | Purpose |
|--------|-----------|---------|
| 0x00   | CTRL      | START pulse, CMD_TYPE (pixel/line), IRQ_EN |
| 0x04   | STATUS    | BUSY and DONE flags (read-only) |
| 0x08   | X0_Y0     | Start coordinates packed into 32 bits |
| 0x0C   | X1_Y1     | End coordinates |
| 0x10   | COLOR     | RGB565 pixel colour |
| 0x14   | FB_BASE   | Physical DDR address of framebuffer |
| 0x18   | FB_STRIDE | Row stride in bytes (default: 2560) |
| 0x1C   | IRQ_CLR   | Write 1 to acknowledge done interrupt |

On START write, it latches coordinates from registers and pulses `cmd_valid`.

---

### `bresenham_core.v`
**Hardware Bresenham line algorithm**

4-state FSM: `IDLE → INIT → DRAW → DONE`

- **INIT** (1 cycle): Computes `dx`, `dy`, `sx`, `sy`, initial `err`
- **DRAW** (N cycles): Outputs 1 pixel per clock. Supports all 8 octants including horizontal, vertical, diagonal, and reverse directions
- **Latency**: 2 cycles from `start` to first `pixel_valid`
- **Throughput**: 1 pixel/clock cycle
- **Coordinate width**: 11-bit (up to 2048 pixels)

---

### `pixel_addr_calc.v`
**Pixel coordinate → DDR address pipeline**

2-stage registered pipeline using DSP48 multiply:

```
Stage 1: row_offset = py × fb_stride   (uses FPGA DSP48 block)
Stage 2: byte_addr  = fb_base + row_offset + (px × 2)
         aligned    = byte_addr & ~7     (8-byte alignment)
         beat_byte  = byte_addr[2:0]     (position within 64-bit beat)
         strobe     = 0b11 << beat_byte  (2 active byte lanes)
```

- **Latency**: 2 clock cycles
- **Throughput**: 1 pixel/clock (fully pipelined; accepts back-to-back from Bresenham)

---

### `axi4_burst_writer.v`
**AXI4 Master burst write engine**

Collects pixel beats from a 512-entry internal FIFO and fires 64-bit wide AXI4 INCR bursts to DDR via the PS HP0 port.

- **FIFO depth**: 512 entries × 104 bits (addr + data + strbe)
- **Burst size**: Up to 256 beats (AXI4 maximum)
- **Trigger**: Fires a burst when FIFO ≥ 256 entries, OR when `flush_req` is asserted
- **Flush**: Asserted by `drawing_engine` after last pixel to drain remaining FIFO entries

States: `IDLE → AW (address) → WDATA (data beats) → BRESP (response) → IDLE`

---

### `drawing_engine.v`
**Top-level draw orchestrator**

Instantiates and connects the three sub-modules (Bresenham → addr_calc → burst_writer). Its FSM handles two command types:

- **CMD_PIXEL (0)**: Directly injects one beat into addr_calc, then flushes
- **CMD_LINE (1)**: Starts Bresenham, relays pixel stream to addr_calc. When Bresenham `done` pulses, asserts `flush_req` and waits for burst writer to drain

---

## Clock Domains

| Domain | Source | Frequency |
|--------|--------|-----------|
| `clk` (AXI fabric) | PS FCLK_CLK0 | 100 MHz |
| Pixel clock | PS FCLK_CLK1 via MMCM | 74.25 MHz (720p60) |

The AXI-stream path from VDMA to rgb2dvi is in the pixel-clock domain. The GPU draw path (Bresenham → burst writer) runs entirely in the AXI fabric clock domain. False paths are declared in the XDC between these two clock domains.

---

## Address Map

| Component | Base Address | Size |
|-----------|-------------|------|
| GPU control registers | `0x4300_0000` | 64 KB |
| AXI VDMA registers | `0x4340_0000` | 64 KB |
| Framebuffer (DDR) | `0x1000_0000` | ~3.5 MB (1280×720×2 bytes) |

---

## Signal Flow: Line Draw Command

```
PS writes X0,Y0,X1,Y1,COLOR,FB_BASE,FB_STRIDE to registers
    │
    ▼
PS writes CTRL[0]=1 (START)
    │
    ▼
gpu_ctrl_axi pulses cmd_valid for 1 clock cycle
    │
    ▼
drawing_engine FSM: IDLE → LINE
    pulses bres_start
    │
    ▼
bresenham_core: IDLE → INIT (1 cycle)
    computes dx, dy, sx, sy, err
    │
    ▼
bresenham_core: DRAW (N cycles, 1 pixel/clock)
    pixel_valid = 1, px/py valid every cycle
    │
    ▼
drawing_engine relays px,py,color to pixel_addr_calc.in_valid
    │
    ▼
pixel_addr_calc (2-cycle pipeline)
    computes 8-byte aligned DDR address + 64-bit data + byte enables
    │
    ▼
axi4_burst_writer FIFO fills
    when count ≥ 256 → fires AXI4 burst to PS HP0 → DDR
    │
    ▼
bresenham_core: DONE (1 cycle, all pixels sent)
    drawing_engine: LINE → FLUSH (asserts flush_req)
    │
    ▼
axi4_burst_writer drains remaining FIFO (partial burst)
    bw_busy falls low
    │
    ▼
drawing_engine: FLUSH → DONE → IDLE
    pulses engine_done
    │
    ▼
gpu_ctrl_axi: sets STATUS[DONE]=1, fires IRQ if IRQ_EN
    │
    ▼
PS Python: reads STATUS, clears IRQ, issues next command
```
