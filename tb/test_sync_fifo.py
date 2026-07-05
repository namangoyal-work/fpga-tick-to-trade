"""sync_fifo — occupancy flags and first-word-fall-through data integrity
under randomized push/pop pressure, checked against a Python deque model.

One coroutine does everything (drive, sample, model), so the model update
and the flag comparison always see the same edge. The model is advanced one
iteration behind: operations decided at falling edge k take effect at rising
edge k+1, so their consequences are checked at falling edge k+1.
"""

import random
from collections import deque

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge
from cocotb.clock import Clock


@cocotb.test()
async def fifo_random_ops(dut):
    Clock(dut.clk, 10, "ns").start()
    dut.rst_n.value = 0
    dut.wr_en.value = 0
    dut.rd_en.value = 0
    dut.wr_data.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await FallingEdge(dut.clk)

    rng = random.Random(0xF1F0)
    depth = 4
    model = deque()
    pending = None   # (do_wr, wdata, do_rd) decided last edge

    for _ in range(3000):
        await FallingEdge(dut.clk)
        # apply last edge's operations to the model
        if pending:
            do_wr, wdata, do_rd = pending
            if do_rd:
                model.popleft()
            if do_wr:
                model.append(wdata)
        # DUT state must now agree with the model
        assert int(dut.empty.value) == (len(model) == 0)
        assert int(dut.full.value) == (len(model) == depth)
        if model:
            assert int(dut.rd_data.value) == model[0], (
                f"rd_data {int(dut.rd_data.value):#x} != head {model[0]:#x}"
            )
        # decide this edge's operations (guards mirror the interface contract)
        wr = rng.random() < 0.5 and len(model) < depth
        rd = rng.random() < 0.5 and len(model) > 0
        wdata = rng.getrandbits(96)
        dut.wr_en.value = 1 if wr else 0
        dut.rd_en.value = 1 if rd else 0
        dut.wr_data.value = wdata
        pending = (wr, wdata, rd)

    dut.wr_en.value = 0
    dut.rd_en.value = 0
