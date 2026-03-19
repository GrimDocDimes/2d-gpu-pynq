#!/usr/bin/env python3
"""
gpu_draw.py — PYNQ Python Driver for 2D GPU Accelerator
=========================================================
Board  : PYNQ-Z2
Overlay: gpu_accel.bit / gpu_accel.hwh

Usage:
    from gpu_draw import GPU, rgb565, VideoOutput
    gpu = GPU(overlay, fb_phys_addr)
    gpu.draw_line(0, 0, 100, 100, 255, 0, 0)
"""

import time
import numpy as np
from pynq import Overlay, allocate

# =============================================================================
# Register map (must match gpu_ctrl_axi.v)
# =============================================================================
REG_CTRL      = 0x00   # [0]=START, [2:1]=CMD_TYPE, [31]=IRQ_EN
REG_STATUS    = 0x04   # [0]=BUSY,  [1]=DONE
REG_X0Y0      = 0x08   # [10:0]=X0, [26:16]=Y0
REG_X1Y1      = 0x0C   # [10:0]=X1, [26:16]=Y1
REG_COLOR     = 0x10   # [15:0]=RGB565
REG_FB_BASE   = 0x14   # [31:0] physical DDR address
REG_FB_STRIDE = 0x18   # [15:0] bytes per row
REG_IRQ_CLR   = 0x1C   # write 1 to clear done IRQ

CMD_PIXEL = 0b00
CMD_LINE  = 0b01

# Screen constants
WIDTH  = 1280
HEIGHT = 720
STRIDE = WIDTH * 2   # RGB565: 2 bytes/pixel


# =============================================================================
# Color utilities
# =============================================================================
def rgb565(r: int, g: int, b: int) -> int:
    """Convert 8-bit R,G,B to 16-bit RGB565 packed integer."""
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)

# Common colour constants (RGB565)
BLACK   = rgb565(0,   0,   0)
WHITE   = rgb565(255, 255, 255)
RED     = rgb565(255, 0,   0)
GREEN   = rgb565(0,   255, 0)
BLUE    = rgb565(0,   0,   255)
CYAN    = rgb565(0,   255, 255)
MAGENTA = rgb565(255, 0,   255)
YELLOW  = rgb565(255, 255, 0)


# =============================================================================
# GPU driver
# =============================================================================
class GPU:
    """
    Hardware-accelerated 2D drawing driver.

    Parameters
    ----------
    ip : pynq IP object
        Returned by overlay.<ip_name>  (e.g. overlay.gpu_ctrl_axi_0)
    fb_phys_addr : int
        Physical DDR address of the framebuffer (from pynq.allocate().device_address)
    fb_array : np.ndarray
        The numpy array backing the framebuffer (for software clear/fill operations)
    width, height : int
        Display resolution (default 1280×720)
    """

    def __init__(self, ip, fb_phys_addr: int, fb_array: np.ndarray,
                 width: int = WIDTH, height: int = HEIGHT):
        self.ip      = ip
        self.width   = width
        self.height  = height
        self.stride  = width * 2
        self._fb     = fb_array  # numpy view into the allocated buffer

        # Initialize hardware registers
        self.set_framebuffer(fb_phys_addr)
        # Enable IRQ in hardware (bit 31 of CTRL)
        self.ip.write(REG_CTRL, 1 << 31)

    # -------------------------------------------------------------------------
    # Framebuffer control
    # -------------------------------------------------------------------------
    def set_framebuffer(self, phys_addr: int):
        """Point the hardware drawing engine at a different physical framebuffer."""
        self.ip.write(REG_FB_BASE,   phys_addr)
        self.ip.write(REG_FB_STRIDE, self.stride)
        self._phys_addr = phys_addr

    # -------------------------------------------------------------------------
    # Low-level command dispatch
    # -------------------------------------------------------------------------
    def _write_command(self, cmd_type: int, x0: int, y0: int,
                       x1: int, y1: int, color: int, timeout_ms: int = 200):
        """Write draw command registers and pulse START. Polls DONE."""
        # Clamp to screen bounds
        x0 = max(0, min(x0, self.width  - 1))
        y0 = max(0, min(y0, self.height - 1))
        x1 = max(0, min(x1, self.width  - 1))
        y1 = max(0, min(y1, self.height - 1))

        self.ip.write(REG_X0Y0,  (y0 << 16) | x0)
        self.ip.write(REG_X1Y1,  (y1 << 16) | x1)
        self.ip.write(REG_COLOR, color & 0xFFFF)
        # Write CTRL: START=1, CMD_TYPE in bits [2:1], IRQ_EN=1
        ctrl = (1 << 31) | (cmd_type << 1) | 0x1
        self.ip.write(REG_CTRL, ctrl)

        # Poll STATUS[DONE] bit
        start_ns = time.monotonic_ns()
        timeout_ns = timeout_ms * 1_000_000
        while True:
            status = self.ip.read(REG_STATUS)
            if status & 0x2:          # DONE bit
                self.ip.write(REG_IRQ_CLR, 1)
                return
            if time.monotonic_ns() - start_ns > timeout_ns:
                raise TimeoutError(
                    f"GPU draw command timed out after {timeout_ms} ms "
                    f"(status=0x{status:08X})"
                )

    # -------------------------------------------------------------------------
    # Drawing primitives
    # -------------------------------------------------------------------------
    def plot_pixel(self, x: int, y: int, color: int):
        """Draw a single pixel at (x, y) with given RGB565 color."""
        self._write_command(CMD_PIXEL, x, y, x, y, color)

    def plot_pixel_rgb(self, x: int, y: int, r: int, g: int, b: int):
        """Draw a single pixel (convenience wrapper with 8-bit RGB input)."""
        self.plot_pixel(x, y, rgb565(r, g, b))

    def draw_line(self, x0: int, y0: int, x1: int, y1: int, color: int):
        """Draw a line from (x0,y0) to (x1,y1) using hardware Bresenham."""
        self._write_command(CMD_LINE, x0, y0, x1, y1, color)

    def draw_line_rgb(self, x0, y0, x1, y1, r, g, b):
        """draw_line with 8-bit RGB color input."""
        self.draw_line(x0, y0, x1, y1, rgb565(r, g, b))

    def draw_hline(self, x: int, y: int, length: int, color: int):
        """Horizontal line — optimised shortcut to draw_line."""
        self.draw_line(x, y, x + length - 1, y, color)

    def draw_vline(self, x: int, y: int, length: int, color: int):
        """Vertical line."""
        self.draw_line(x, y, x, y + length - 1, color)

    def draw_rect(self, x: int, y: int, w: int, h: int, color: int):
        """Hollow rectangle — 4 hardware draw_line calls."""
        self.draw_hline(x,       y,       w, color)  # top
        self.draw_hline(x,       y + h-1, w, color)  # bottom
        self.draw_vline(x,       y,       h, color)  # left
        self.draw_vline(x + w-1, y,       h, color)  # right

    def draw_triangle(self, x0, y0, x1, y1, x2, y2, color: int):
        """Draw triangle outline using 3 lines."""
        self.draw_line(x0, y0, x1, y1, color)
        self.draw_line(x1, y1, x2, y2, color)
        self.draw_line(x2, y2, x0, y0, color)

    def draw_circle(self, cx: int, cy: int, r: int, color: int, segments: int = 72):
        """
        Draw circle outline using N line segments (software decomposition).
        For a hardware circle, implement Bresenham's circle in RTL later.
        """
        import math
        prev_x = cx + r
        prev_y = cy
        for i in range(1, segments + 1):
            angle = 2 * math.pi * i / segments
            nx = cx + int(r * math.cos(angle))
            ny = cy + int(r * math.sin(angle))
            self.draw_line(prev_x, prev_y, nx, ny, color)
            prev_x, prev_y = nx, ny

    # -------------------------------------------------------------------------
    # Software framebuffer operations (numpy — fast for full-frame ops)
    # -------------------------------------------------------------------------
    def clear(self, color: int = BLACK):
        """Fill entire framebuffer with a color (software, uses numpy)."""
        self._fb[:] = color

    def fill_rect(self, x: int, y: int, w: int, h: int, color: int):
        """Filled rectangle via numpy slice (fast on PS side)."""
        self._fb[y:y+h, x:x+w] = color

    def blit(self, image: np.ndarray, dst_x: int = 0, dst_y: int = 0):
        """
        Copy a numpy uint16 image into the framebuffer at (dst_x, dst_y).
        image must be shape (H, W) dtype=uint16 (RGB565).
        """
        h, w = image.shape[:2]
        self._fb[dst_y:dst_y+h, dst_x:dst_x+w] = image

    @property
    def status(self) -> dict:
        """Read engine status register."""
        s = self.ip.read(REG_STATUS)
        return {'busy': bool(s & 0x1), 'done': bool(s & 0x2)}


# =============================================================================
# Video Output — VDMA framebuffer display management
# =============================================================================
class VideoOutput:
    """
    Manages double-buffering and VDMA display channel.

    Parameters
    ----------
    vdma : pynq VDMA IP object
    width, height : int
    """

    def __init__(self, vdma, width: int = WIDTH, height: int = HEIGHT):
        self.vdma   = vdma
        self.width  = width
        self.height = height

        # Allocate two framebuffers
        self.fb = [
            allocate(shape=(height, width), dtype=np.uint16),
            allocate(shape=(height, width), dtype=np.uint16),
        ]
        self._front = 0  # index of buffer currently displayed
        self._back  = 1  # index of buffer being drawn into

        # Configure VDMA read channel
        mm2s = vdma.readchannel
        mm2s.mode = VideoMode(width, height, 16)
        mm2s.start()
        self._show(self._front)

    def _show(self, idx: int):
        """Point VDMA at framebuffer[idx]."""
        self.vdma.readchannel.framebuffer_addr = self.fb[idx].device_address

    def flip(self):
        """Swap front and back buffers (show what was drawn, draw on old front)."""
        self._show(self._back)
        self._front, self._back = self._back, self._front

    @property
    def back_buffer(self) -> np.ndarray:
        """Numpy array of the current back (drawing) buffer."""
        return self.fb[self._back]

    @property
    def back_phys(self) -> int:
        """Physical DDR address of back buffer."""
        return self.fb[self._back].device_address


# =============================================================================
# Quick demo function (run on PYNQ board)
# =============================================================================
def run_demo(overlay_path: str = '/home/xilinx/jupyter_notebooks/gpu/gpu_accel.bit'):
    """
    Complete end-to-end demo:
      1. Load bitstream
      2. Allocate framebuffers
      3. Draw shapes into back buffer
      4. Flip to display
    """
    print("Loading overlay...")
    ol = Overlay(overlay_path)

    print("Setting up video output...")
    video = VideoOutput(ol.axi_vdma_0)

    print("Creating GPU driver...")
    gpu = GPU(ol.gpu_ctrl_axi_0,
              fb_phys_addr=video.back_phys,
              fb_array=video.back_buffer)

    print("Drawing scene...")

    # Clear to dark blue
    gpu.clear(rgb565(0, 0, 40))

    # Big red X across screen
    gpu.draw_line_rgb(0, 0, WIDTH-1, HEIGHT-1, 255, 50, 50)
    gpu.draw_line_rgb(WIDTH-1, 0, 0, HEIGHT-1, 255, 50, 50)

    # Green rectangle border
    gpu.draw_rect(50, 50, WIDTH-100, HEIGHT-100, GREEN)

    # White cross at center
    gpu.draw_hline(WIDTH//2 - 50, HEIGHT//2, 100, WHITE)
    gpu.draw_vline(WIDTH//2, HEIGHT//2 - 50, 100, WHITE)

    # Cyan circle
    gpu.draw_circle(WIDTH//2, HEIGHT//2, 200, CYAN, segments=120)

    # Yellow triangle
    gpu.draw_triangle(
        WIDTH//2, 100,
        100, HEIGHT-100,
        WIDTH-100, HEIGHT-100,
        YELLOW
    )

    print("Flipping buffer...")
    video.flip()

    print("Demo complete! Press Enter to exit.")
    input()


if __name__ == '__main__':
    run_demo()
