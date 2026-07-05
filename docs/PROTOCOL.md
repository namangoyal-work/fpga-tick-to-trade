# Wire formats

Two 16-byte fixed-size formats, both defined by this project: **MDM-16** (the
market-data message the engine consumes) and **TTD-16** (the decision record
it produces). All multi-byte fields are network byte order (big-endian).

## Carrier frame

One MDM-16 message per UDP datagram (v1):

```
bytes  0..13   Ethernet II   dst MAC = engine MAC (or broadcast), EtherType 0x0800
bytes 14..33   IPv4          IHL=5 (no options), proto=17, not fragmented,
                             total length = exactly 44, header checksum valid
bytes 34..41   UDP           dst port = LISTEN_PORT, length = exactly 24
bytes 42..57   MDM-16        payload (below)
bytes 58..     padding       to the 60-byte Ethernet minimum; ignored
```

Anything violating a constraint above is rejected fail-closed: the engine
still emits a verdict at fixed latency, but the action is NONE and no record
is generated. Frame byte 57 — the last MDM-16 byte — is the **anchor**: the
decision emerges exactly `LATENCY` clock cycles after that byte's beat.

## MDM-16 — market-data message

| offset | size | field     | encoding                                                |
|-------:|-----:|-----------|---------------------------------------------------------|
|      0 |    1 | magic     | `0xA5`                                                   |
|      1 |    1 | ver/type  | bits [7:4] version, must be `1`; bits [3:0] message type |
|      2 |    2 | symbol_id | instrument identifier                                    |
|      4 |    1 | side      | `0x00` = BID, `0x01` = ASK; all other values rejected    |
|      5 |    1 | reserved  | must be `0x00`                                           |
|      6 |    4 | price     | unsigned, ticks of 1e-4 (999500 = 99.9500)               |
|     10 |    2 | qty       | unsigned                                                 |
|     12 |    4 | seq       | publisher sequence number, echoed into TTD-16            |

Message types: `1` = QUOTE (can trigger a trade), `2` = TRADE (accepted as
structurally valid, never triggers in v1). Other types are rejected.

Design notes:

- **Fixed size, no optional fields.** Every field offset is a compile-time
  constant, which is what allows a counter-indexed parser with zero buffering
  and a data-independent decision time.
- **`seq` is 32-bit and echoed** so the host can correlate each decision
  record with the tick that caused it and measure end-to-end tick-to-trade
  latency without timestamps in the hot path.
- **`reserved` is must-be-zero**, not ignored: tolerated garbage in reserved
  fields is how protocol confusion starts.

## TTD-16 — trade decision record

Emitted on the decision AXI-Stream (the DMA-facing boundary) only when a
decision fires. One record is 16 bytes, `tlast` on the final byte:

| offset | size | field     | encoding                                        |
|-------:|-----:|-----------|-------------------------------------------------|
|      0 |    1 | magic     | `0x5A`                                          |
|      1 |    1 | action    | `0x01` = BUY, `0x02` = SELL                     |
|      2 |    2 | symbol_id | echo of the triggering quote                    |
|      4 |    4 | price     | echo of the triggering quote                    |
|      8 |    2 | qty       | order quantity, already capped at `MAX_QTY`     |
|     10 |    4 | seq       | echo of the triggering quote                    |
|     14 |    1 | flags     | `0x00` (reserved)                               |
|     15 |    1 | check     | XOR of bytes 0..14                              |

The XOR check byte exists for the software side of the boundary: a host
consumer (DMA ring or UART reader) can detect a torn or corrupted record and
resynchronize on the next magic. `tools/read_decisions.py` implements this.
