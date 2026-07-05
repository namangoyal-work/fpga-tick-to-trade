#!/usr/bin/env python3
"""Read and decode TTD-16 decision records from the Arty's USB-UART.

Usage:
    python3 tools/read_decisions.py /dev/tty.usbserial-XXXX
    (find the port with: ls /dev/tty.usb* on macOS, /dev/ttyUSB* on Linux)

Requires pyserial:  pip install pyserial

Synchronizes on the 0x5A record magic, validates the XOR check byte, and
prints one decoded line per record. A corrupt or out-of-sync byte stream
resynchronizes on the next magic rather than aborting.
"""

import struct
import sys

try:
    import serial  # type: ignore
except ImportError:
    sys.exit("pyserial not installed: pip install pyserial")

ACTIONS = {1: "BUY ", 2: "SELL"}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    port = serial.Serial(sys.argv[1], 115200, timeout=None)
    print(f"listening on {sys.argv[1]} @ 115200 8N1 (ctrl-c to stop)")
    buf = b""
    n = 0
    while True:
        buf += port.read(max(1, 16 - len(buf)))
        # resync: drop bytes until the buffer starts with the record magic
        while buf and buf[0] != 0x5A:
            buf = buf[1:]
        if len(buf) < 16:
            continue
        rec, buf = buf[:16], buf[16:]
        chk = 0
        for b in rec[:15]:
            chk ^= b
        if chk != rec[15]:
            print(f"  !! bad checksum, resyncing: {rec.hex()}")
            buf = rec[1:] + buf
            continue
        _, action, symbol, price, qty, seq, _ = struct.unpack(">BBHIHIB", rec[:15])
        n += 1
        print(
            f"#{n:<4d} {ACTIONS.get(action, f'?{action}')} "
            f"symbol=0x{symbol:04X} price={price / 1e4:.4f} "
            f"qty={qty} seq={seq} [{rec.hex()}]"
        )


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
