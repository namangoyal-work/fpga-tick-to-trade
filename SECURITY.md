# Security

This is a wire-facing filter that turns untrusted network bytes into trade
actions, so its security posture is part of its function, not an add-on.

## Threat model

**In scope:** arbitrary hostile bytes on the ingress stream — malformed
headers, fragments, IP options, truncated frames (runts), oversized frames,
corrupted checksums, invalid MDM-16 structure, boundary-value prices, and
flooding at line rate.

**Out of scope:** physical/side-channel attacks, fault injection, a
compromised synthesis toolchain, and attacks on the host software that
consumes the decision stream (that is the software project's threat model).

## Properties and how they are enforced

- **Fail-closed by construction.** Every validation flag powers up and resets
  to "reject"; a verdict is accept only if every check affirmatively passed.
  Runt frames force action NONE through an explicit override, because their
  flags may hold stale values from a previous frame.
- **No fire without validation — proven, not tested.**
  `formal/trade_trigger.sby` proves by k-induction that any non-NONE decision
  implies every parser flag (MAC, EtherType, IPv4, UDP, MDM-16), the symbol
  match, and the QUOTE type were simultaneously high, and the frame was not a
  runt — for *every* possible input sequence, not a sampled set.
- **Deterministic timing.** The decision emerges at a constant cycle offset
  for accepts, rejects, and runts alike (proven, and measured per-frame in
  the benches). Response-time side channels that leak *which* check failed do
  not exist at the decision output.
- **No wedge, no overflow into the hot path.** Ingress `tready` is
  structurally tied high (a hostile stream cannot stall the engine), and a
  flooded decision queue drops records with a sticky `overflow` flag rather
  than backpressuring the trigger. The fuzz campaign asserts exactly one
  verdict per frame — no wedges, no duplicates — across 300 adversarial cases.
- **Deterministic power-up (CWE-1271).** All state, including datapath
  registers, has a reset value; power-up state equals reset state and no `X`
  propagates.
- **Strict structural checks.** Exact IP total length, exact UDP length,
  must-be-zero reserved field, closed side/type/version sets. Tolerated slop
  in "don't care" fields is how protocol-confusion attacks start, so there is
  none.

## Known, deliberate exclusions

- **UDP checksum is not verified.** It spans a pseudo-header borrowing
  IP-layer state; verifying it would couple stages that are otherwise
  independently provable, and the IP header checksum already covers the
  routing-critical fields. This is a header-triage filter; end-to-end payload
  integrity belongs to the endpoint. (The MDM-16 structural checks partially
  compensate.)
- **Ethernet FCS is not checked.** The engine assumes a MAC that drops
  CRC-invalid frames (standard behaviour). If fed by a raw PHY without FCS
  filtering, corrupted-but-well-formed frames could pass; the IP checksum
  bounds, but does not eliminate, that exposure.
- **No rate limiting / no per-flow state.** A hostile line-rate flood of
  *valid* firing quotes produces line-rate decisions until the queue drops.
  `MAX_QTY` caps per-order size, but aggregate-exposure risk controls belong
  to the software layer above.

## Reporting

Open a GitHub issue for anything in scope above. If a finding contradicts a
formal claim, please include the `.sby` trace or the failing bench seed —
both are reproducible by design.
