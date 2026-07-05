"""md_parser — MDM-16 structural checks and field extraction."""

import cocotb
from cocotb.triggers import ClockCycles

from mdm import build_frame
from tb_util import send_frame, setup


async def run_case(dut, frame):
    await send_frame(dut, frame)
    await ClockCycles(dut.clk, 2)
    return int(dut.md_ok.value)


@cocotb.test()
async def md_directed(dut):
    await setup(dut)

    frame = build_frame(msg_type=1, symbol=0x0001, side=1,
                        price=999_500, qty=250, seq=0xDEADBEEF)
    assert await run_case(dut, frame) == 1, "valid QUOTE rejected"
    assert int(dut.msg_type.value) == 1
    assert int(dut.symbol_id.value) == 0x0001
    assert int(dut.side.value) == 1
    assert int(dut.price.value) == 999_500
    assert int(dut.qty.value) == 250
    assert int(dut.seq.value) == 0xDEADBEEF, "seq extraction wrong"

    assert await run_case(dut, build_frame(msg_type=2)) == 1, "valid TRADE rejected"
    assert int(dut.msg_type.value) == 2

    assert await run_case(dut, build_frame(magic=0xA6)) == 0, "bad magic accepted"
    assert await run_case(dut, build_frame(version=2)) == 0, "unknown version accepted"
    assert await run_case(dut, build_frame(msg_type=3)) == 0, "unknown type accepted"
    assert await run_case(dut, build_frame(side=2)) == 0, "invalid side accepted"
    assert await run_case(dut, build_frame(resv=1)) == 0, "non-zero reserved accepted"
