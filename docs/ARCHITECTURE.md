# Architecture

## Pipeline

```
            byte-wide AXI-Stream, one byte per cycle, never backpressured
   ┌────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌───────────┐
──▶│  eth   │──▶│  ipv4   │──▶│   udp   │──▶│   md    │──▶│  trade    │
   │ parser │   │ parser  │   │ parser  │   │ parser  │   │ trigger   │
   └───┬────┘   └────┬────┘   └────┬────┘   └────┬────┘   └─────┬─────┘
       │ mac_ok      │ ip_ok       │ udp_ok      │ md_ok        │ decision
       │ type_ok     │             │             │ fields       ▼ (fixed latency)
       └─────────────┴─────────────┴─────────────┘        ┌───────────┐
                     validation flags ────────────────────▶│ decision  │──▶ TTD-16
                                                           │ emitter   │    AXI-Stream
                                                           └───────────┘    (DMA-facing)
```

Every stage taps the same combinationally-passed-through byte stream, so all
per-stage byte counters advance in lockstep and field offsets are fixed
compile-time constants. The stages are *observers*; elasticity lives in one
dedicated module (`axis_skid`, formally proven) that is inserted only where a
measurement says the ready chain is the bottleneck.

## Latency model

The engine's product is not average speed but *determinism*: the decision for
every frame — accept, reject, or runt — emerges exactly `LATENCY` cycles
(default 5) after the anchor beat (frame byte 57). At 100 MHz that is 50 ns
from last payload byte to decision; the property is proven for all inputs by
k-induction (`formal/trade_trigger.sby`), and measured per-frame by the
benches.

Budget from the wire's perspective (100 MHz, one byte per cycle):

| event                                | cycle  |
|--------------------------------------|--------|
| first frame byte enters              | t      |
| anchor byte (57, last MDM-16 byte)   | t + 57 |
| flags/fields settle in parser FFs    | t + 58 |
| decision_valid, record enqueued      | t + 62 |
| 16-byte TTD-16 record fully streamed | t + 79 (unstalled consumer) |

There is no CPU, no cache, no interrupt anywhere in that path — which is the
entire argument for doing this in fabric.

## Backpressure model (asymmetric, on purpose)

- **Ingress cannot stall.** `s_tready` is tied high: you cannot flow-control
  a market feed. Every stage keeps up at one byte per cycle unconditionally.
- **Egress can stall arbitrarily.** The decision emitter absorbs downstream
  stalls in a small FIFO. If decisions fire faster than the consumer drains,
  records are *dropped* (never stalling the trigger) and a sticky `overflow`
  flag is raised — losing telemetry loudly beats corrupting the fixed-latency
  engine silently.

## Hardware/software boundary

The TTD-16 stream is the contract. In deployment it feeds a DMA engine
writing into host memory, where a busy-polling SPSC ring consumer (the
software half of this project) picks records up without syscalls. On the
Arty A7 demo the same stream drains over the USB-UART instead — same bytes,
same records, observable with a serial terminal.

## Clocking and reset

Single clock domain (board demo: the raw 100 MHz Arty oscillator; the core
characterizes far higher — see README results). Synchronous, active-low
reset. Every register, including datapath registers, has a reset value, so
power-up state equals reset state and no `X` can propagate (CWE-1271).

## Parameters

| parameter     | default          | meaning                                  |
|---------------|------------------|------------------------------------------|
| `MY_MAC`      | 02:00:00:C0:FF:EE| accepted unicast destination MAC         |
| `LISTEN_PORT` | 47100            | accepted UDP destination port            |
| `SYMBOL_ID`   | 0x0001           | instrument the strategy watches          |
| `BUY_THRESH`  | 1,000,000        | fire BUY on ASK quotes priced ≤ this     |
| `SELL_THRESH` | 1,010,000        | fire SELL on BID quotes priced ≥ this    |
| `MAX_QTY`     | 100              | hard cap on emitted order quantity       |
| `LATENCY`     | 5                | anchor beat → decision_valid, in cycles  |
