"""Shared bench plumbing.

Edge discipline used by every bench in this repo: the DUT clocks on rising
edges; the bench reads and drives only at falling edges. A value read at a
falling edge is exactly the value the DUT will sample at the next rising
edge, and a value driven at a falling edge is in effect for that edge — so
"will a beat happen at the next rising edge?" is decidable mid-cycle with no
race. Anything that must be timestamped consistently (anchor beats and
decision pulses, say) is observed by a single coroutine with a single local
counter, because the wake order of two coroutines on the same edge is
unspecified.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly

CLK_NS = 10

ANCHOR = 57   # frame byte whose beat anchors the fixed-latency decision


async def setup(dut, extra_inputs=()):
    """Start the clock, zero the inputs, pulse reset."""
    Clock(dut.clk, CLK_NS, "ns").start()
    dut.rst_n.value = 0
    for name in ("s_tdata", "s_tvalid", "s_tlast"):
        if hasattr(dut, name):
            getattr(dut, name).value = 0
    if hasattr(dut, "m_tready"):
        dut.m_tready.value = 1
    for name in extra_inputs:
        getattr(dut, name).value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await FallingEdge(dut.clk)


async def send_frame(dut, frame, stall=0.0, rng=None):
    """Stream one frame, one offered byte per beat, honouring s_tready.

    stall: probability of a one-cycle tvalid gap before each byte (needs rng).

    Self-aligns to a falling edge first: callers commonly arrive here from
    ClockCycles, which returns on a rising edge, and a byte driven mid-high-
    phase is overwritten before any rising edge can sample it.
    """
    await FallingEdge(dut.clk)
    for i, byte in enumerate(frame):
        if stall and rng and rng.random() < stall:
            dut.s_tvalid.value = 0
            await FallingEdge(dut.clk)
        dut.s_tdata.value = byte
        dut.s_tlast.value = 1 if i == len(frame) - 1 else 0
        dut.s_tvalid.value = 1
        while True:
            accepted = int(dut.s_tready.value) == 1
            await FallingEdge(dut.clk)
            if accepted:
                break
    dut.s_tvalid.value = 0
    dut.s_tlast.value = 0


class StreamMonitor:
    """Single-coroutine observer for the tick2trade_top benches.

    Tracks, against one local falling-edge counter:
      * anchor beats (frame byte 57) and runt ends (tlast before byte 57)
        on the ingress stream,
      * decision_valid pulses and their action,
      * decision-record bytes on the egress stream, split on tlast.
    """

    def __init__(self):
        self.events = []      # cycle numbers of anchor/runt beats, in order
        self.decisions = []   # (cycle, action) per decision_valid pulse
        self.records = []     # completed 16-byte records
        self._cur = []
        self._n = 0
        self._idx = 0

    async def run(self, dut):
        while True:
            await FallingEdge(dut.clk)
            # Sample in the ReadOnly phase: bench writes land in the ReadWrite
            # phase after all coroutines have run, so reading straight after
            # the edge would see driver signals one edge stale (while DUT
            # outputs are current), skewing every timestamp by one.
            await ReadOnly()
            self._n += 1
            if int(dut.s_tvalid.value) and int(dut.s_tready.value):
                last = int(dut.s_tlast.value)
                if self._idx == ANCHOR:
                    self.events.append(self._n)
                elif last and self._idx < ANCHOR:
                    self.events.append(self._n)
                self._idx = 0 if last else self._idx + 1
            if int(dut.decision_valid.value):
                self.decisions.append((self._n, int(dut.decision_action.value)))
            if int(dut.m_tvalid.value) and int(dut.m_tready.value):
                self._cur.append(int(dut.m_tdata.value))
                if int(dut.m_tlast.value):
                    self.records.append(bytes(self._cur))
                    self._cur = []


async def drain(dut, cycles=120):
    """Idle long enough for any in-flight decision and record to emerge."""
    await ClockCycles(dut.clk, cycles)
