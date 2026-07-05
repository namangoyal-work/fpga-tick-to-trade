"""udp_parser — directed port and length checks."""

import cocotb
from cocotb.triggers import ClockCycles

from mdm import LISTEN_PORT, build_frame, mdm16
from tb_util import send_frame, setup


async def run_case(dut, frame):
    await send_frame(dut, frame)
    await ClockCycles(dut.clk, 2)
    return int(dut.udp_ok.value)


@cocotb.test()
async def udp_directed(dut):
    await setup(dut)

    assert await run_case(dut, build_frame()) == 1, "valid frame rejected"
    assert int(dut.dst_port.value) == LISTEN_PORT, "dst_port extraction wrong"
    assert int(dut.src_port.value) == 51000, "src_port extraction wrong"
    assert int(dut.udp_len.value) == 24, "udp_len extraction wrong"

    assert await run_case(dut, build_frame(dport=LISTEN_PORT + 1)) == 0, \
        "wrong dst port accepted"

    # byte-order trap: the right port arriving byte-swapped must not match
    swapped = ((LISTEN_PORT & 0xFF) << 8) | (LISTEN_PORT >> 8)
    assert await run_case(dut, build_frame(dport=swapped)) == 0, \
        "byte-swapped port accepted"

    # declared length must be exactly header + one MDM-16 message; a 17-byte
    # payload moves the declared length to 25
    assert await run_case(dut, build_frame(payload=mdm16() + b"\x00")) == 0, \
        "oversized datagram accepted"
