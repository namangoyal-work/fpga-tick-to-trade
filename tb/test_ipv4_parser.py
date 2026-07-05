"""ipv4_parser — directed header validation and checksum checks.

Valid stimulus is scapy-encoded, so "the checksum verifies" is a claim about
agreement with an independent implementation, not self-agreement. Cases that
must isolate one check (fragment, protocol, length) let scapy recompute the
checksum so only the targeted check fails.
"""

import cocotb
from cocotb.triggers import ClockCycles
from scapy.all import IP, UDP, Ether, raw  # type: ignore

from mdm import LISTEN_PORT, MY_MAC, SRC_MAC, build_frame, mdm16
from tb_util import send_frame, setup


def scapy_frame(**ip_kwargs):
    ip_kwargs.setdefault("flags", 0)
    f = raw(
        Ether(dst=MY_MAC, src=SRC_MAC)
        / IP(src="10.0.0.2", dst="10.0.0.1", **ip_kwargs)
        / UDP(sport=51000, dport=LISTEN_PORT)
        / mdm16()
    )
    return f.ljust(60, b"\x00")


async def run_case(dut, frame):
    await send_frame(dut, frame)
    await ClockCycles(dut.clk, 2)
    return int(dut.ip_ok.value)


@cocotb.test()
async def ipv4_directed(dut):
    await setup(dut)

    assert await run_case(dut, build_frame()) == 1, "valid frame rejected"
    assert int(dut.src_ip.value) == 0x0A000002, "src_ip extraction wrong"
    assert int(dut.dst_ip.value) == 0x0A000001, "dst_ip extraction wrong"

    # corrupt one checksum byte: only csum verification should catch it
    f = bytearray(build_frame())
    f[24] ^= 0xFF
    assert await run_case(dut, bytes(f)) == 0, "bad checksum accepted"

    # corrupt a summed header byte (TTL): stored checksum no longer matches
    f = bytearray(build_frame())
    f[22] ^= 0x01
    assert await run_case(dut, bytes(f)) == 0, "corrupted header accepted"

    # fragments (checksum recomputed by scapy, so only nofrag fails)
    assert await run_case(dut, scapy_frame(flags="MF")) == 0, "MF fragment accepted"
    assert await run_case(dut, scapy_frame(frag=100)) == 0, "offset fragment accepted"
    # Don't-Fragment is legitimate and must pass
    assert await run_case(dut, scapy_frame(flags="DF")) == 1, "DF frame rejected"

    # wrong protocol, wrong declared length, IP options
    assert await run_case(dut, scapy_frame(proto=6)) == 0, "TCP protocol accepted"
    assert await run_case(dut, scapy_frame(len=45)) == 0, "wrong total length accepted"
    assert await run_case(dut, scapy_frame(ihl=6, len=48)) == 0, "IP options accepted"
