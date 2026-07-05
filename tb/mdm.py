"""Shared frame construction and golden decision model for the benches.

Frames are built with scapy — a third, independent implementation of the
Ethernet/IPv4/UDP encodings — so header checksums and lengths in "valid"
stimulus do not originate from the same code being tested.

`golden_decision` is a from-scratch reimplementation of the core's decision
rules over raw wire bytes. It shares a *spec interpretation* with the RTL but
no code;
"""

import struct

from scapy.all import IP, UDP, Ether, raw  # type: ignore

# Core configuration mirrored by the DUT parameters in the benches.
MY_MAC = "02:00:00:c0:ff:ee"
MY_MAC_B = bytes.fromhex(MY_MAC.replace(":", ""))
BCAST_B = b"\xff" * 6
SRC_MAC = "02:00:00:aa:bb:cc"
LISTEN_PORT = 47100
SYMBOL_ID = 0x0001
BUY_THRESH = 1_000_000
SELL_THRESH = 1_010_000
MAX_QTY = 100

ANCHOR = 57          # frame byte carrying the last MDM-16 byte
MIN_FRAME = ANCHOR + 1

ACT_NONE, ACT_BUY, ACT_SELL = 0, 1, 2


def mdm16(msg_type=1, symbol=SYMBOL_ID, side=1, price=999_500, qty=10,
          seq=1, magic=0xA5, version=1, resv=0):
    """Build a 16-byte MDM-16 payload (defaults: BUY-firing ASK quote)."""
    return struct.pack(
        ">BBHBBIHI", magic, ((version & 0xF) << 4) | (msg_type & 0xF),
        symbol, side, resv, price, qty, seq,
    )


def build_frame(payload=None, dst_mac=MY_MAC, dport=LISTEN_PORT,
                pad_to=60, **mdm_kwargs):
    """One Ethernet/IPv4/UDP frame around an MDM-16 payload, scapy-encoded."""
    if payload is None:
        payload = mdm16(**mdm_kwargs)
    f = raw(
        Ether(dst=dst_mac, src=SRC_MAC)
        / IP(src="10.0.0.2", dst="10.0.0.1", flags=0)
        / UDP(sport=51000, dport=dport)
        / payload
    )
    return f.ljust(pad_to, b"\x00")


def golden_decision(w: bytes):
    """Reference decision over raw wire bytes.

    Returns (action, record) where record is the expected TTD-16 field tuple
    (symbol, price, qty_capped, seq) for a fired decision, else None.
    """
    if len(w) < MIN_FRAME:
        return ACT_NONE, None                              # runt
    if w[0:6] != MY_MAC_B and w[0:6] != BCAST_B:
        return ACT_NONE, None                              # not our MAC
    if (w[12] << 8 | w[13]) != 0x0800:
        return ACT_NONE, None                              # not IPv4
    if w[14] != 0x45:
        return ACT_NONE, None                              # options / not v4
    if (w[16] << 8 | w[17]) != 44:
        return ACT_NONE, None                              # wrong total length
    if (w[20] & 0x3F) != 0 or w[21] != 0:
        return ACT_NONE, None                              # fragment
    if w[23] != 0x11:
        return ACT_NONE, None                              # not UDP
    s = sum((w[i] << 8 | w[i + 1]) for i in range(14, 34, 2))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    if s != 0xFFFF:
        return ACT_NONE, None                              # bad IP checksum
    if (w[36] << 8 | w[37]) != LISTEN_PORT:
        return ACT_NONE, None                              # wrong port
    if (w[38] << 8 | w[39]) != 24:
        return ACT_NONE, None                              # wrong UDP length
    if w[42] != 0xA5 or (w[43] >> 4) != 1:
        return ACT_NONE, None                              # bad magic/version
    msg_type = w[43] & 0x0F
    if msg_type not in (1, 2):
        return ACT_NONE, None
    side = w[46]
    if side not in (0, 1) or w[47] != 0:
        return ACT_NONE, None
    symbol = w[44] << 8 | w[45]
    price = int.from_bytes(w[48:52], "big")
    qty = w[52] << 8 | w[53]
    seq = int.from_bytes(w[54:58], "big")

    if msg_type != 1 or symbol != SYMBOL_ID:
        return ACT_NONE, None
    if side == 1 and price <= BUY_THRESH:
        action = ACT_BUY
    elif side == 0 and price >= SELL_THRESH:
        action = ACT_SELL
    else:
        return ACT_NONE, None
    return action, (symbol, price, min(qty, MAX_QTY), seq)


def expected_record(action, rec):
    """The exact 16 TTD-16 bytes the emitter must produce for a decision."""
    symbol, price, qty, seq = rec
    body = struct.pack(">BBHIHIB", 0x5A, action, symbol, price, qty, seq, 0)
    chk = 0
    for b in body:
        chk ^= b
    return body + bytes([chk])
