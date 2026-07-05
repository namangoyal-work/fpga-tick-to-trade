"""tick2trade_top — golden-model fuzz.

300 adversarial frames against an independent Python reimplementation of the
decision rules (tb/mdm.py), with valid stimulus encoded by scapy. Three
structural properties are checked independently of the golden model: every
frame produces exactly one decision pulse (no wedge, no duplicate), the
ingress never stalls, and every emitted record carries a valid XOR check.

The seed is fixed: a failure in CI must be reproducible and bisectable, and
the assertion message carries the exact wire bytes for replay. The case mix
is weighted toward near-boundary corruption (1–4 flipped header/payload
bytes), because that is where a filter fails dangerously.
"""

import random

import cocotb
from cocotb.triggers import ClockCycles

from mdm import (ACT_NONE, BUY_THRESH, SELL_THRESH, build_frame,
                 expected_record, golden_decision, mdm16)
from tb_util import StreamMonitor, send_frame, setup

N_CASES = 300


def make_case(rng):
    kind = rng.random()
    if kind < 0.35:
        # pristine frame, parameters swept across the decision boundaries
        price = rng.choice([
            rng.randrange(0, 2**32),
            BUY_THRESH + rng.randrange(-3, 4),
            SELL_THRESH + rng.randrange(-3, 4),
        ])
        return build_frame(
            msg_type=rng.choice([1, 1, 1, 2]),
            symbol=rng.choice([1, 1, 1, 2, 0xFFFF]),
            side=rng.choice([0, 1]),
            price=price,
            qty=rng.randrange(0, 65536),
            seq=rng.randrange(0, 2**32),
        )
    if kind < 0.75:
        # valid frame with 1..4 corrupted bytes: nearest the accept boundary
        f = bytearray(build_frame(side=rng.choice([0, 1]),
                                  price=rng.randrange(900_000, 1_100_000),
                                  qty=rng.randrange(0, 300),
                                  seq=rng.randrange(0, 2**32)))
        for _ in range(rng.randrange(1, 5)):
            f[rng.randrange(len(f))] ^= rng.randrange(1, 256)
        return bytes(f)
    if kind < 0.90:
        # unstructured garbage, including runts
        return bytes(rng.randrange(256) for _ in range(rng.randrange(10, 80)))
    # right shape, wrong port
    return build_frame(dport=rng.randrange(1, 65536),
                       side=1, price=999_000, seq=rng.randrange(0, 2**32))


@cocotb.test()
async def fuzz_against_golden(dut):
    await setup(dut)
    mon = StreamMonitor()
    cocotb.start_soon(mon.run(dut))

    rng = random.Random(0xC0FFEE)
    expected_records = []
    for i in range(N_CASES):
        frame = make_case(rng)
        action, rec = golden_decision(frame)
        if action != ACT_NONE:
            expected_records.append((i, frame, expected_record(action, rec)))

        dec_before = len(mon.decisions)
        assert int(dut.s_tready.value) == 1, "ingress dropped tready (wedge)"
        await send_frame(dut, frame, stall=0.1, rng=rng)
        await ClockCycles(dut.clk, 30)

        got = mon.decisions[dec_before:]
        assert len(got) == 1, (
            f"case {i}: {len(got)} decisions for one frame "
            f"(wedge/duplicate), wire={frame.hex()}"
        )
        assert got[0][1] == action, (
            f"case {i}: action {got[0][1]}, golden {action}, wire={frame.hex()}"
        )

    await ClockCycles(dut.clk, 200)
    assert len(mon.records) == len(expected_records), (
        f"{len(mon.records)} records vs {len(expected_records)} expected"
    )
    for (i, frame, exp), got in zip(expected_records, mon.records):
        assert got == exp, (
            f"case {i}: record {got.hex()} != expected {exp.hex()}, "
            f"wire={frame.hex()}"
        )
        chk = 0
        for b in got[:15]:
            chk ^= b
        assert chk == got[15], f"case {i}: record checksum invalid"
