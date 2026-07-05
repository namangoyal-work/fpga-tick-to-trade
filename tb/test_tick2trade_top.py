"""tick2trade_top — end-to-end directed cases and the latency measurement.

The StreamMonitor timestamps anchor/runt beats and decision pulses against
one local counter, so "decision_valid arrives exactly LATENCY cycles after
the anchor beat" is measured, not assumed — for accepts, rejects, and runts
alike. Record bytes are compared against the independent golden encoder.
"""

import cocotb
from cocotb.triggers import ClockCycles

from mdm import (ACT_BUY, ACT_NONE, ACT_SELL, BUY_THRESH, SELL_THRESH,
                 build_frame, expected_record, golden_decision)
from tb_util import StreamMonitor, drain, send_frame, setup

LATENCY = 5


@cocotb.test()
async def top_directed(dut):
    await setup(dut)
    mon = StreamMonitor()
    cocotb.start_soon(mon.run(dut))

    cases = [
        # (frame, comment)
        (build_frame(side=1, price=BUY_THRESH - 500, qty=250, seq=0x42),
         "ASK below threshold -> BUY, qty capped 250->100"),
        (build_frame(side=1, price=BUY_THRESH, qty=10, seq=2),
         "ASK exactly at threshold -> BUY (boundary is inclusive)"),
        (build_frame(side=0, price=SELL_THRESH, qty=50, seq=3),
         "BID at sell threshold -> SELL"),
        (build_frame(side=1, price=BUY_THRESH + 1, qty=10, seq=4),
         "ASK one tick above threshold -> no fire (boundary)"),
        (build_frame(side=0, price=SELL_THRESH - 1, qty=10, seq=5),
         "BID one tick below sell threshold -> no fire"),
        (build_frame(symbol=0x0002, side=1, price=1000, seq=6),
         "wrong symbol -> no fire"),
        (build_frame(msg_type=2, side=1, price=1000, seq=7),
         "TRADE message -> valid, but only QUOTEs fire"),
        (build_frame(dst_mac="ff:ff:ff:ff:ff:ff", side=1, price=1000, seq=8),
         "broadcast MAC -> fires"),
        (build_frame(dst_mac="02:00:00:c0:ff:00", side=1, price=1000, seq=9),
         "wrong MAC -> no fire"),
        (build_frame(dport=1234, side=1, price=1000, seq=10),
         "wrong UDP port -> no fire"),
    ]
    # corrupted IP checksum -> header reject
    f = bytearray(build_frame(side=1, price=1000, seq=11))
    f[24] ^= 0xFF
    cases.append((bytes(f), "corrupted IP checksum -> no fire"))

    expected_records = []
    for frame, why in cases:
        action, rec = golden_decision(frame)
        if action != ACT_NONE:
            expected_records.append(expected_record(action, rec))
        await send_frame(dut, frame)
        await drain(dut, 60)

    n = len(cases)
    assert len(mon.events) == n, f"{len(mon.events)} anchor events for {n} frames"
    assert len(mon.decisions) == n, (
        f"{len(mon.decisions)} decisions for {n} frames (wedge or duplicate)"
    )
    for i, ((frame, why), ev, (dec_cyc, action)) in enumerate(
            zip(cases, mon.events, mon.decisions)):
        assert dec_cyc - ev == LATENCY, (
            f"case {i} ({why}): decision after {dec_cyc - ev} cycles, "
            f"expected {LATENCY}"
        )
        exp_action, _ = golden_decision(frame)
        assert action == exp_action, (
            f"case {i} ({why}): action {action}, expected {exp_action}"
        )
    assert mon.records == expected_records, "record bytes disagree with golden"


@cocotb.test()
async def top_runt_fixed_latency(dut):
    """A frame truncated mid-header still yields exactly one decision, action
    NONE, at the same fixed offset from its runt (tlast) beat."""
    await setup(dut)
    mon = StreamMonitor()
    cocotb.start_soon(mon.run(dut))

    await send_frame(dut, build_frame()[:30])   # dies inside the IP header
    await drain(dut, 60)
    # a runt must not poison the next valid frame
    good = build_frame(side=1, price=1000, seq=77)
    await send_frame(dut, good)
    await drain(dut, 60)

    assert len(mon.decisions) == 2, f"{len(mon.decisions)} decisions, expected 2"
    (r_cyc, r_act), (g_cyc, g_act) = mon.decisions
    assert r_act == ACT_NONE, "runt fired a trade"
    assert r_cyc - mon.events[0] == LATENCY, "runt verdict not at fixed latency"
    assert g_act == ACT_BUY, "valid frame after runt did not fire"
    assert g_cyc - mon.events[1] == LATENCY
    action, rec = golden_decision(good)
    assert mon.records == [expected_record(action, rec)]


@cocotb.test()
async def top_back_to_back(dut):
    """Two frames with zero idle gap: two decisions, two records, both at
    fixed latency — the per-frame state fully re-initializes at byte 0."""
    await setup(dut)
    mon = StreamMonitor()
    cocotb.start_soon(mon.run(dut))

    f1 = build_frame(side=1, price=1000, qty=5, seq=100)
    f2 = build_frame(side=0, price=SELL_THRESH + 999, qty=7, seq=101)
    await send_frame(dut, f1)
    await send_frame(dut, f2)   # immediately: no idle cycle between frames
    await drain(dut)

    assert len(mon.decisions) == 2
    assert [a for _, a in mon.decisions] == [ACT_BUY, ACT_SELL]
    for ev, (dec_cyc, _) in zip(mon.events, mon.decisions):
        assert dec_cyc - ev == LATENCY
    expected = [expected_record(*golden_decision(f)) for f in (f1, f2)]
    assert mon.records == expected


@cocotb.test()
async def top_tvalid_gaps(dut):
    """Mid-frame tvalid gaps (a bursty MAC) must not skew the byte counters:
    all per-byte logic is gated on beats, not on valid alone."""
    import random
    await setup(dut)
    mon = StreamMonitor()
    cocotb.start_soon(mon.run(dut))

    rng = random.Random(0xBEEF)
    frame = build_frame(side=1, price=1000, qty=9, seq=55)
    await send_frame(dut, frame, stall=0.3, rng=rng)
    await drain(dut)

    assert [a for _, a in mon.decisions] == [ACT_BUY]
    action, rec = golden_decision(frame)
    assert mon.records == [expected_record(action, rec)]
