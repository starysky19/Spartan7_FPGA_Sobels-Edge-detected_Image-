#!/usr/bin/env python3
"""
GUI for the Real Digital Boolean / Spartan-7 FPGA image-filter demo.

Protocol:
  PC -> FPGA: 0xA5 + 16384 grayscale bytes (128x128)
  FPGA -> PC: 0x5A + 16384 filtered grayscale bytes

The FPGA performs the 3x3 Sobel edge detector. Python only loads/resizes images,
transfers bytes, and displays/saves the returned FPGA result.
"""
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from pathlib import Path

from PIL import Image, ImageTk
import serial
from serial.tools import list_ports

IMAGE_W = 128
NUM_PIXELS = IMAGE_W * IMAGE_W
BAUD = 115200
INPUT_HEADER = b"\xA5"
OUTPUT_HEADER = b"\x5A"


class ImageFilterApp:
    def __init__(self, root):
        self.root = root
        self.root.title("Spartan-7 FPGA Image Filter")
        self.root.geometry("980x700")
        self.input_path = None
        self.original_gray = None
        self.original_preview = None
        self.filtered_preview = None

        outer = ttk.Frame(root, padding=12)
        outer.pack(fill="both", expand=True)

        ttk.Label(
            outer, text="Spartan-7 FPGA 3×3 Sobel Edge Detector",
            font=("Segoe UI", 16, "bold")
        ).pack(anchor="w", pady=(0, 8))

        controls = ttk.Frame(outer)
        controls.pack(fill="x", pady=(0, 10))

        ttk.Button(controls, text="Choose image…", command=self.choose_image).pack(side="left")
        ttk.Label(controls, text="Serial port:").pack(side="left", padx=(18, 5))
        self.port_var = tk.StringVar()
        self.port_combo = ttk.Combobox(controls, textvariable=self.port_var, width=22, state="readonly")
        self.port_combo.pack(side="left")
        ttk.Button(controls, text="Refresh", command=self.refresh_ports).pack(side="left", padx=5)
        self.run_button = ttk.Button(controls, text="Send to FPGA and filter", command=self.start_filter)
        self.run_button.pack(side="left", padx=(10, 0))

        self.file_label = ttk.Label(outer, text="No image selected.")
        self.file_label.pack(anchor="w", pady=(0, 8))

        self.status_var = tk.StringVar(value="Connect the Boolean board via its PROG UART USB port, program the bitstream, then select a COM port.")
        ttk.Label(outer, textvariable=self.status_var, wraplength=920).pack(anchor="w", pady=(0, 8))

        images = ttk.Frame(outer)
        images.pack(fill="both", expand=True)
        self.original_panel = self.make_image_panel(images, "Original (converted to 128×128 grayscale)")
        self.filtered_panel = self.make_image_panel(images, "Filtered result returned by FPGA")

        self.refresh_ports()

    def make_image_panel(self, parent, title):
        frame = ttk.LabelFrame(parent, text=title, padding=8)
        frame.pack(side="left", fill="both", expand=True, padx=5)
        label = ttk.Label(frame, text="Image preview appears here", anchor="center")
        label.pack(fill="both", expand=True)
        return label

    def refresh_ports(self):
        ports = [p.device for p in list_ports.comports()]
        self.port_combo["values"] = ports
        if ports and self.port_var.get() not in ports:
            self.port_var.set(ports[0])
        if not ports:
            self.port_var.set("")
            self.status_var.set("No serial port found. Connect the board with a data-capable USB cable and refresh.")

    def choose_image(self):
        path = filedialog.askopenfilename(
            title="Choose an image",
            filetypes=[("Image files", "*.png *.jpg *.jpeg *.bmp *.tif *.tiff"), ("All files", "*.*")]
        )
        if not path:
            return
        try:
            img = Image.open(path).convert("L")
            self.input_path = Path(path)
            self.original_gray = img.resize((IMAGE_W, IMAGE_W), Image.Resampling.LANCZOS)
            self.file_label.config(text=f"Selected: {self.input_path}")
            self.original_preview = ImageTk.PhotoImage(self.original_gray.resize((320, 320), Image.Resampling.NEAREST))
            self.original_panel.config(image=self.original_preview, text="")
            self.filtered_panel.config(image="", text="Filtered result appears after FPGA processing")
            self.filtered_preview = None
            self.status_var.set("Image loaded. Select the board's serial port and click 'Send to FPGA and filter'.")
        except Exception as exc:
            messagebox.showerror("Could not open image", str(exc))

    def start_filter(self):
        if self.original_gray is None:
            messagebox.showwarning("Choose an image", "Choose a JPG or PNG image first.")
            return
        port = self.port_var.get().strip()
        if not port:
            messagebox.showwarning("Choose serial port", "Select the COM/serial port for the Boolean board.")
            return
        self.run_button.config(state="disabled")
        self.status_var.set("Transferring image to FPGA and waiting for filtered pixels…")
        threading.Thread(target=self.transfer_worker, args=(port,), daemon=True).start()

    def transfer_worker(self, port):
        try:
            pixels = self.original_gray.tobytes()
            if len(pixels) != NUM_PIXELS:
                raise RuntimeError(f"Internal error: expected {NUM_PIXELS} pixels, got {len(pixels)}.")

            # The board's USB UART appears as a COM/serial port.
            with serial.Serial(port, BAUD, timeout=30, write_timeout=30) as ser:
                ser.reset_input_buffer()
                ser.reset_output_buffer()
                # Allow the serial driver to settle before sending the command.
                import time
                time.sleep(0.15)
                ser.write(INPUT_HEADER + pixels)
                ser.flush()

                header = ser.read(1)
                if header != OUTPUT_HEADER:
                    raise RuntimeError(
                        f"Did not receive FPGA response header 0x5A. Received {header!r}. "
                        "Check that the correct bitstream is programmed and the selected port is correct."
                    )

                result = ser.read(NUM_PIXELS)
                if len(result) != NUM_PIXELS:
                    raise RuntimeError(
                        f"Timed out receiving image: received {len(result)} of {NUM_PIXELS} bytes."
                    )

            filtered = Image.frombytes("L", (IMAGE_W, IMAGE_W), result)
            output_path = self.input_path.with_name(self.input_path.stem + "_fpga_sobel.png")
            filtered.save(output_path)
            self.root.after(0, self.show_result, filtered, output_path)
        except Exception as exc:
            self.root.after(0, self.show_error, str(exc))

    def show_result(self, filtered, output_path):
        self.filtered_preview = ImageTk.PhotoImage(filtered.resize((320, 320), Image.Resampling.NEAREST))
        self.filtered_panel.config(image=self.filtered_preview, text="")
        self.status_var.set(
            f"Success! FPGA returned {NUM_PIXELS} filtered pixels. Saved output to: {output_path}"
        )
        self.run_button.config(state="normal")
        messagebox.showinfo("Filtering complete", f"Filtered image saved to:\n{output_path}")

    def show_error(self, message):
        self.status_var.set("Transfer failed.")
        self.run_button.config(state="normal")
        messagebox.showerror("FPGA image-filter error", message)


def main():
    root = tk.Tk()
    ImageFilterApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
