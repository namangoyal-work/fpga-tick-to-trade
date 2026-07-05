# Running on hardware (Arty A7)

The demo streams a canned quote frame from on-chip ROM into the engine ~3×
per second. Switches corrupt the frame live, LEDs show the outcome, and the
TTD-16 decision records arrive on the USB-UART. The results in the README
were produced with exactly the flows on this page.

## Prerequisites

- Vivado (non-project batch Tcl; any recent version)
- Arty A7-100T (default) or A7-35T (`ARTY_PART=xc7a35ticsg324-1L`)
- micro-USB cable — the one connector carries power, JTAG, and the UART
- `pip install pyserial` for the record reader

## Core characterization (no board required)

```bash
vivado -mode batch -source synth/char.tcl
```

Synthesizes the reusable core (`tick2trade_top`) out-of-context against a
deliberately aggressive 4 ns probe clock. From `build/char_timing.rpt`:

```
Fmax = 1 / (4 ns − WNS)
```

`build/char_utilization.rpt` gives the core's LUT/FF footprint with the
board wrapper excluded. The expected critical path is *not* the checksum
fold — it is pipelined precisely so that it cannot be the limiter (see the
design rationale, §3). If a report disagrees, that is a rationale defect:
open an issue.

## Building and programming the demo

```bash
vivado -mode batch -source synth/build_bitstream.tcl   # → build/fpga_top.bit
```

Confirm `build/timing_summary.rpt` reports timing met at 100 MHz, then
program the board from the machine it is attached to:

```bash
vivado -mode batch -source synth/program.tcl     # JTAG, volatile (SRAM)
# or, without Vivado:
openFPGALoader -b arty_a7_100t build/fpga_top.bit
```

Both load configuration SRAM: the design starts immediately and is lost on
power cycle. For a persistent image, write the SPI flash instead — see the
`write_cfgmem` notes at the bottom of `synth/program.tcl`.

## On-board verification sequence

Start with all switches down.

| step | action | expected |
|---|---|---|
| 1 | program the board | `led[3]` blinks ~1.5 Hz — design alive |
| 2 | — | `led[1]` blinks ~3×/s (one verdict per frame) and `led[0]` blinks with it (each frame fires a BUY) |
| 3 | `sw[0]` up (corrupt price) | `led[0]` stops; `led[1]` keeps blinking — the engine still issues a verdict for every frame |
| 4 | `sw[0]` down, `sw[1]` up (corrupt IP checksum) | same: `led[0]` off, `led[1]` on |
| 5 | `sw[1]` down, `sw[2]` up (corrupt UDP port) | same |
| 6 | all down, hold `btn[0]` (reset) | LEDs stop; release → activity resumes |
| 7 | `python3 tools/read_decisions.py <port>` | one record per frame period: `BUY symbol=0x0001 price=99.9500 qty=100 seq=66` |
| 8 | flip `sw[1]` while the reader runs | records stop; flip back → records resume, all check bytes valid |

Step 7's `qty=100` — against the quote's 250 — is the formally proven
`MAX_QTY` risk cap, observed on silicon.

`led[2]` (sticky decision-queue overflow) should never light at the demo
frame rate; the UART drains faster than decisions arrive. If it lights, the
overflow flag is doing its job — investigate the consumer.

## Serial port names

| platform | typical device |
|---|---|
| Linux | `/dev/ttyUSB1` (the second interface of the FTDI chip) |
| macOS | `/dev/tty.usbserial-XXXXX` (`ls /dev/tty.usb*`) |

The UART runs 8N1 at 115200 baud.
