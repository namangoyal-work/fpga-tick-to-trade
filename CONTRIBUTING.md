# Contributing

## Setup

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r tb/requirements.txt
# simulator: Icarus Verilog (brew install icarus-verilog / apt install iverilog)
# formal:    Yosys + SymbiYosys + z3 (or the OSS CAD Suite bundle)
```

## Running the checks

```bash
make -C tb regress                       # every bench + the fuzz campaign
make -C tb DUT=<module> sim              # one module's bench
sby -f formal/axis_skid.sby              # each proof, from the repo root
sby -f formal/trade_trigger.sby
sby -f formal/sync_fifo.sby
iverilog -g2012 -Irtl -o /dev/null rtl/*.sv   # elaboration lint
```

CI runs all of the above on every push; green CI is the merge bar.

## Design rules (the invariants reviews enforce)

1. **Per-byte logic is gated on beats** (`tvalid && tready`), never on
   `tvalid` alone.
2. **Parser stages are observers**: combinational passthrough, flags as
   registered outputs, no buffering inside a parser. Elasticity is
   `axis_skid`, inserted where a measurement demands it.
3. **Fail closed.** New checks default to reject on reset and at byte 0;
   accept requires an affirmative match. Runts must never fire.
4. **Fixed latency is a contract.** Anything touching `trade_trigger` must
   keep the formal properties passing unchanged (or change them *explicitly*
   with the reasoning in the PR).
5. **Every register gets a reset value**, including datapath registers.
6. **Portability:** code must elaborate under Icarus (`-g2012`) *and*
   synthesize under Vivado. Icarus is CI-gated; Vivado is exercised by the
   synthesis flows in `synth/`. Known divergences and their workarounds are
   documented in the
   [design rationale](https://github.com/namangoyal-work/DesignRationale).
7. **Network byte order traps get a test.** Any multi-byte field assembly
   must have a directed test with a byte-swapped negative case.

## Verification expectations for a PR

- New RTL behaviour ⇒ a directed cocotb case, and a golden-model update if
  the decision rules changed (`tb/mdm.py` — keep it an *independent*
  reimplementation; do not import constants from generated RTL).
- New handshake or state machine ⇒ formal properties in an
  `` `ifdef FORMAL `` block plus a `.sby` job wired into CI.
- Bench changes: calibrate against a known-good reference first (see the
  [design rationale](https://github.com/namangoyal-work/DesignRationale) §12
  for why).

## Style

- `default_nettype none` per file; byte-wide AXI-Stream subset
  (`tdata/tvalid/tlast/tready`) for streams.
- Comments state constraints the code cannot (why a width, why an order, why
  a guard) — not what the next line does.
- Commit messages: imperative subject, body explains *why*.

## Documentation duty

If you make a non-obvious design decision, add its defense to the
[design rationale](https://github.com/namangoyal-work/DesignRationale) in the
same PR. An undefended decision is a documentation bug in this repo.
