"""eth_parser — directed MAC and EtherType checks.

Flags are contract-valid only while hdr_done is high; each case streams one
frame and samples flags right after it completes, before the next frame's
byte 0 re-initializes them.
"""

import cocotb
from cocotb.triggers import ClockCycles

from mdm import build_frame
from tb_util import send_frame, setup


async def run_case(dut, frame):
    await send_frame(dut, frame)
    await ClockCycles(dut.clk, 2)
    return int(dut.mac_ok.value), int(dut.type_ok.value), int(dut.hdr_done.value)


@cocotb.test()
async def eth_directed(dut):
    await setup(dut)

    mac_ok, type_ok, done = await run_case(dut, build_frame())
    assert (mac_ok, type_ok, done) == (1, 1, 1), "valid unicast frame rejected"

    mac_ok, type_ok, _ = await run_case(dut, build_frame(dst_mac="ff:ff:ff:ff:ff:ff"))
    assert (mac_ok, type_ok) == (1, 1), "broadcast frame rejected"

    mac_ok, _, _ = await run_case(dut, build_frame(dst_mac="02:00:00:c0:ff:ef"))
    assert mac_ok == 0, "wrong dst MAC accepted (last byte off by one)"

    mac_ok, _, _ = await run_case(dut, build_frame(dst_mac="12:00:00:c0:ff:ee"))
    assert mac_ok == 0, "wrong dst MAC accepted (first byte wrong)"

    f = bytearray(build_frame())
    f[12], f[13] = 0x86, 0xDD   # IPv6 EtherType
    _, type_ok, _ = await run_case(dut, bytes(f))
    assert type_ok == 0, "non-IPv4 EtherType accepted"

    # byte-order trap: 0x0800 arriving little-endian must NOT match
    f = bytearray(build_frame())
    f[12], f[13] = 0x00, 0x08
    _, type_ok, _ = await run_case(dut, bytes(f))
    assert type_ok == 0, "byte-swapped EtherType accepted"

    # flags must re-initialize per frame: bad frame after good one
    await run_case(dut, build_frame())
    mac_ok, _, _ = await run_case(dut, build_frame(dst_mac="02:00:00:c0:ff:00"))
    assert mac_ok == 0, "stale mac_ok survived into the next frame"
