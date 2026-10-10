# Spartan-7 Boolean Board: 128x128 FPGA Sobel Edge Detector

This project resizes a selected image to **128x128 grayscale** on the PC, transfers the 16,384 grayscale bytes to the Real Digital Boolean / Spartan-7 FPGA over UART, performs a **3x3 Sobel edge detector in the FPGA**, and receives a 128x128 grayscale edge map.

## Hardware and protocol
- Board: Real Digital Boolean, Spartan-7 XC7S50-CSGA324
- Clock: 100 MHz
- UART: 115200 baud, 8 data bits, no parity, 1 stop bit (8-N-1)
- Image: 128 x 128 grayscale (16,384 bytes)
- Input packet: `0xA5`, then 16,384 grayscale pixel bytes
- Output packet: `0x5A`, then 16,384 Sobel edge pixels
- Filter: 3x3 Sobel Gx/Gy kernels with zero padding at image boundaries
- Magnitude approximation: `min(255, abs(Gx) + abs(Gy))`; high-contrast edges become white and flat areas become black

The Python GUI only converts/resizes, sends/receives, and displays/saves images. The Sobel arithmetic is implemented in synthesizable SystemVerilog on the FPGA. This uses a sequential nine-tap calculation per output pixel, prioritizing simple, understandable RTL over throughput.

## Files
- `rtl/image_filter_top.sv`: RTL, Sobel arithmetic, UART RX/TX
- `sim/image_filter_tb.sv`: 4x4 UART-level Sobel simulation testbench
- `constraints/boolean_board.xdc`: Boolean board pin assignments
- `python/fpga_image_filter_gui.py`: desktop GUI

## Setup
Install Python dependencies:
```bash
python -m pip install pillow pyserial
```
In Vivado, create an RTL project for `xc7s50csga324-1`, add `rtl/image_filter_top.sv` as Design Source and `constraints/boolean_board.xdc` as Constraint Source, and set `image_filter_top` as the design top. Add `sim/image_filter_tb.sv` as Simulation Source and set `image_filter_tb` as the simulation top for testing. Expected simulation message: `PASS: All 16 pixels match expected 3x3 Sobel edge magnitudes.`

Run synthesis, implementation, generate the bitstream, then program the board via Hardware Manager. Keep the board out of reset during transfers.

Run the GUI from the extracted project directory:
```bash
python python/fpga_image_filter_gui.py
```
Choose an image, select the board COM port, then click **Send to FPGA and filter**. Output is saved beside the input as `<original-name>_fpga_sobel.png`.

## Notes and troubleshooting
- At 115200 baud, sending and receiving 16,384 bytes each takes roughly 2.9 seconds per direction before protocol overhead; allow up to 30 seconds for the full operation.
- Close other serial-terminal apps before running the GUI.
- If no COM port appears, use a data-capable USB cable and check Device Manager.
- If the response header `0x5A` is missing, verify the programmed bitstream, top module, COM port, and reset state.
- Sobel output is an edge map, not a sharpened or averaged version of the input. Thin high-contrast boundaries should be bright; flat areas should be dark. The displayed preview is enlarged with nearest-neighbor interpolation so pixels remain visible.
- Boundary pixels use zero padding, which can create artificial edge responses along the image border.
