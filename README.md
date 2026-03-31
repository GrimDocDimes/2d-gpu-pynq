# 2D GPU Accelerator for PYNQ-Z2

A hardware-accelerated 2D graphics engine implemented on the Xilinx Zynq-7000 SoC (PYNQ-Z2). The PL (FPGA fabric) implements a Bresenham line engine, AXI4 burst pixel writer, and an AXI4-Lite control register file. The PS drives it through a clean Python API.

## Features

- **Bresenham line drawing** in hardware — 1 pixel/clock cycle, all 8 octants
- **Single pixel plot** command
- **AXI4 burst write** to DDR framebuffer (64-bit wide, 256-beat bursts)
- **RGB565** colour format (1280 × 720 native)
- **AXI4-Lite** slave register interface for PS control
- **IRQ** notification on draw-complete
- **Python driver** (`gpu_draw.py`) with `draw_line`, `draw_rect`, `draw_circle`, `draw_triangle`, `fill_rect`, etc.
- Double-buffered display via AXI VDMA + HDMI TX

## Hardware Requirements

- PYNQ-Z2 board (Zynq XC7Z020-1CLG400C)
- HDMI display connected to HDMI-OUT
- Vivado 2022.1 or later (for building the bitstream)
- PYNQ image v3.0 or later on the board

## Repository Structure

```
2d-gpu-pynq/
├── hdl/                    # Verilog RTL source
│   ├── bresenham_core.v    # Hardware Bresenham line algorithm
│   ├── drawing_engine.v    # Top-level draw engine (instantiates submodules)
│   ├── pixel_addr_calc.v   # Pixel → DDR address pipeline
│   ├── axi4_burst_writer.v # AXI4 master burst write engine
│   └── gpu_ctrl_axi.v      # AXI4-Lite slave register file
├── sim/                    # Testbenches
│   ├── tb_bresenham.v
│   ├── tb_pixel_addr_calc.v
│   └── tb_drawing_engine.v
├── ip_repo/                # Packaged Vivado IP
│   └── gpu_ctrl_axi_1.0/
├── constraints/
│   └── pynq_z2.xdc         # PYNQ-Z2 pin/timing constraints
├── scripts/
│   └── build_project.tcl   # Automated Vivado block design builder
├── pynq/
│   └── gpu_draw.py         # Python driver for the GPU IP
├── notebooks/
│   └── gpu_demo.ipynb      # Jupyter demo notebook
└── docs/
    └── architecture.md     # Architecture overview
```

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/GrimDocDimes/2d-gpu-pynq.git
cd 2d-gpu-pynq
```

### 2. Run Simulations (Icarus Verilog — no Vivado needed)

```bash
# Bresenham core
iverilog -o sim/tb_bres.out sim/tb_bresenham.v hdl/bresenham_core.v
vvp sim/tb_bres.out

# Pixel address calculator
iverilog -o sim/tb_pac.out sim/tb_pixel_addr_calc.v hdl/pixel_addr_calc.v
vvp sim/tb_pac.out

# Full drawing engine
iverilog -o sim/tb_eng.out \
  sim/tb_drawing_engine.v \
  hdl/drawing_engine.v hdl/bresenham_core.v \
  hdl/pixel_addr_calc.v hdl/axi4_burst_writer.v
vvp sim/tb_eng.out
```

### 3. Build Bitstream (requires Vivado)

```bash
vivado -mode batch -source scripts/build_project.tcl
```

The script creates `gpu_project/` in the current directory and generates:
- `gpu_project/gpu_project.runs/impl_1/gpu_top_wrapper.bit`
- Copy it to the PYNQ board along with the `.hwh` file.

### 4. Deploy to PYNQ-Z2

Copy the overlay files to the board:

```bash
scp gpu_project/gpu_accel.bit xilinx@<board-ip>:/home/xilinx/jupyter_notebooks/gpu/
scp gpu_project/gpu_accel.hwh xilinx@<board-ip>:/home/xilinx/jupyter_notebooks/gpu/
scp pynq/gpu_draw.py          xilinx@<board-ip>:/home/xilinx/jupyter_notebooks/gpu/
scp notebooks/gpu_demo.ipynb  xilinx@<board-ip>:/home/xilinx/jupyter_notebooks/gpu/
```

Default board credentials: user `xilinx`, password `xilinx`.

### 5. Run the Demo

Open the Jupyter notebook at `http://<board-ip>:9090` and run `gpu/gpu_demo.ipynb`.

## Register Map

| Offset | Name       | Description                              |
|--------|------------|------------------------------------------|
| 0x00   | CTRL       | `[0]`=START, `[2:1]`=CMD_TYPE, `[31]`=IRQ_EN |
| 0x04   | STATUS     | `[0]`=BUSY, `[1]`=DONE (read-only)      |
| 0x08   | X0_Y0      | `[10:0]`=X0, `[26:16]`=Y0               |
| 0x0C   | X1_Y1      | `[10:0]`=X1, `[26:16]`=Y1               |
| 0x10   | COLOR      | `[15:0]`=RGB565 colour                   |
| 0x14   | FB_BASE    | Framebuffer physical DDR base address    |
| 0x18   | FB_STRIDE  | Bytes per row (default 2560 for 1280px)  |
| 0x1C   | IRQ_CLR    | Write 1 to clear done interrupt          |

## Python API

```python
from gpu_draw import GPU, VideoOutput, rgb565, RED, GREEN, BLUE, WHITE

# Setup (inside Jupyter on PYNQ)
from pynq import Overlay
ol = Overlay('/home/xilinx/jupyter_notebooks/gpu/gpu_accel.bit')

video = VideoOutput(ol.axi_vdma_0)
gpu   = GPU(ol.gpu_ctrl_axi_0,
            fb_phys_addr=video.back_phys,
            fb_array=video.back_buffer)

# Draw
gpu.clear(rgb565(0, 0, 40))
gpu.draw_line(0, 0, 1279, 719, RED)
gpu.draw_rect(50, 50, 400, 300, GREEN)
gpu.draw_circle(640, 360, 200, WHITE, segments=120)
video.flip()
```

## Architecture

See [docs/architecture.md](docs/architecture.md) for the full block diagram and signal flow description.

## License

MIT — see [LICENSE](LICENSE) for details.
