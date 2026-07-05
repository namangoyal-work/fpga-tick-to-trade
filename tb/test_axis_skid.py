"""axis_skid — data integrity under randomized backpressure.

Driver and consumer/checker are separate coroutines that never touch the
same signal; the scoreboard (a plain list) is the only thing between them.
Bytes are logged at OFFER time: AXI-Stream guarantees an offered byte
transfers exactly once and in order, so the offer sequence is exactly the
sequence that must emerge, and the entry provably exists before any output
beat can carry it.
"""

import random

import cocotb
from cocotb.triggers import FallingEdge, with_timeout

from tb_util import setup

N_BYTES = 2000


async def driver(dut, scoreboard, rng):
    sent = 0
    while sent < N_BYTES:
        if rng.random() < 0.3:   # input gaps: a bubble in must be a bubble out
            dut.s_tvalid.value = 0
            await FallingEdge(dut.clk)
            continue
        byte = rng.randrange(256)
        last = 1 if (sent % 40 == 39) else 0
        dut.s_tdata.value = byte
        dut.s_tlast.value = last
        dut.s_tvalid.value = 1
        scoreboard.append((byte, last))
        while True:
            accepted = int(dut.s_tready.value) == 1
            await FallingEdge(dut.clk)
            if accepted:
                break
        sent += 1
    dut.s_tvalid.value = 0


async def consumer_checker(dut, scoreboard, rng, done):
    got = 0
    while got < N_BYTES:
        await FallingEdge(dut.clk)
        ready = 1 if rng.random() < 0.6 else 0
        dut.m_tready.value = ready
        if ready and int(dut.m_tvalid.value) == 1:
            # a beat occurs at the upcoming rising edge; data is stable now
            assert scoreboard, f"byte {got} emerged with an empty scoreboard (duplication)"
            exp_byte, exp_last = scoreboard.pop(0)
            act_byte = int(dut.m_tdata.value)
            act_last = int(dut.m_tlast.value)
            assert (act_byte, act_last) == (exp_byte, exp_last), (
                f"byte {got}: got ({act_byte:#04x}, last={act_last}), "
                f"expected ({exp_byte:#04x}, last={exp_last})"
            )
            got += 1
    done.append(True)


@cocotb.test()
async def skid_random_backpressure(dut):
    await setup(dut)
    rng = random.Random(0xC0FFEE)
    scoreboard = []
    done = []
    cocotb.start_soon(consumer_checker(dut, scoreboard, rng, done))
    cocotb.start_soon(driver(dut, scoreboard, rng))

    async def wait_done():
        while not done:
            await FallingEdge(dut.clk)

    # wedge detector: fail loudly instead of hanging CI
    await with_timeout(wait_done(), 1_000_000, "ns")
    assert not scoreboard, f"{len(scoreboard)} bytes never emerged (dropped)"


@cocotb.test()
async def skid_full_throughput(dut):
    """With a never-stalling consumer, the skid buffer sustains one byte per
    cycle: N back-to-back offers all land, none rejected."""
    await setup(dut)
    dut.m_tready.value = 1
    rejected = 0
    for i in range(200):
        dut.s_tdata.value = i & 0xFF
        dut.s_tlast.value = 0
        dut.s_tvalid.value = 1
        if int(dut.s_tready.value) != 1:
            rejected += 1
        await FallingEdge(dut.clk)
    dut.s_tvalid.value = 0
    assert rejected == 0, f"{rejected} stalls with an always-ready consumer"
