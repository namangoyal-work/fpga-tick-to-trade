"""decision_emitter — record serialization, checksum, stall and overflow.

The emitter sits between a producer that can never stall (the trigger) and a
consumer that can. These tests hammer exactly that asymmetry.
"""

import random

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge

from mdm import ACT_BUY, ACT_SELL, expected_record
from tb_util import setup

DEC_INPUTS = ("decision_valid", "decision_action", "decision_symbol",
              "decision_price", "decision_qty", "decision_seq")


async def pulse_decision(dut, action, symbol=1, price=999_500, qty=100, seq=7):
    await FallingEdge(dut.clk)   # self-align: see tb_util.send_frame
    dut.decision_action.value = action
    dut.decision_symbol.value = symbol
    dut.decision_price.value = price
    dut.decision_qty.value = qty
    dut.decision_seq.value = seq
    dut.decision_valid.value = 1
    await FallingEdge(dut.clk)
    dut.decision_valid.value = 0


async def collect_records(dut, n_expected, rng=None, max_cycles=3000):
    """Drive m_tready (randomly if rng given) and collect records."""
    records, cur = [], []
    for _ in range(max_cycles):
        await FallingEdge(dut.clk)
        ready = 1 if (rng is None or rng.random() < 0.5) else 0
        dut.m_tready.value = ready
        if ready and int(dut.m_tvalid.value) == 1:
            cur.append(int(dut.m_tdata.value))
            if int(dut.m_tlast.value):
                records.append(bytes(cur))
                cur = []
                if len(records) == n_expected:
                    return records
    raise AssertionError(
        f"only {len(records)}/{n_expected} records after {max_cycles} cycles"
    )


@cocotb.test()
async def emitter_single_record(dut):
    await setup(dut, extra_inputs=DEC_INPUTS)
    await pulse_decision(dut, ACT_BUY, symbol=0x0001, price=999_500,
                         qty=100, seq=0x42)
    (rec,) = await collect_records(dut, 1)
    assert rec == expected_record(ACT_BUY, (0x0001, 999_500, 100, 0x42)), (
        f"record bytes wrong: {rec.hex()}"
    )
    assert int(dut.overflow.value) == 0


@cocotb.test()
async def emitter_stalled_consumer(dut):
    """Records must come out intact when the consumer stalls randomly
    mid-record — the serializer may not skip or repeat bytes."""
    await setup(dut, extra_inputs=DEC_INPUTS)
    dut.m_tready.value = 0   # hold records back until the collector drives ready
    rng = random.Random(0x51A11)
    expected = []
    for i, action in enumerate([ACT_BUY, ACT_SELL, ACT_BUY]):
        await pulse_decision(dut, action, symbol=i, price=1000 + i,
                             qty=i + 1, seq=i)
        expected.append(expected_record(action, (i, 1000 + i, i + 1, i)))
        await ClockCycles(dut.clk, 40)
    got = await collect_records(dut, 3, rng=rng)
    assert got == expected, "records corrupted under consumer stall"


@cocotb.test()
async def emitter_none_action_no_record(dut):
    await setup(dut, extra_inputs=DEC_INPUTS)
    await pulse_decision(dut, 0)   # NONE: a verdict, not a trade
    await ClockCycles(dut.clk, 50)
    assert int(dut.m_tvalid.value) == 0, "record emitted for a NONE decision"
    assert int(dut.fire.value) == 0


@cocotb.test()
async def emitter_overflow_drops_not_stalls(dut):
    """Six fired decisions against a wedged consumer: one in the serializer,
    four in the queue, the sixth dropped with the sticky flag raised. The
    producer is never stalled and the five buffered records drain intact."""
    await setup(dut, extra_inputs=DEC_INPUTS)
    dut.m_tready.value = 0
    expected = []
    for i in range(6):
        await pulse_decision(dut, ACT_BUY, symbol=i, price=100 + i,
                             qty=1, seq=i)
        if i < 5:
            expected.append(expected_record(ACT_BUY, (i, 100 + i, 1, i)))
        await ClockCycles(dut.clk, 3)
    assert int(dut.overflow.value) == 1, "overflow not flagged"
    got = await collect_records(dut, 5)
    assert got == expected, "buffered records corrupted by the overflow"
    await ClockCycles(dut.clk, 30)
    assert int(dut.m_tvalid.value) == 0, "more records than expected"
