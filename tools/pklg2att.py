#!/usr/bin/env python3
"""
pklg2att.py — turn an Apple PacketLogger capture (.pklg) into an ATT timeline.

    python3 tools/pklg2att.py capture.pklg            # human readable timeline
    python3 tools/pklg2att.py capture.pklg --json     # JSON lines
    python3 tools/pklg2att.py capture.pklg --handles  # just the handle → UUID map

It reassembles L2CAP fragments, follows GATT discovery responses so every ATT
handle is labelled with its UUID, and prints reads, writes, notifications and
indications with their payloads. No dependencies beyond the standard library.
"""
import argparse
import datetime as dt
import json
import struct
import sys

PKT_TYPES = {
    0x00: "HCI_CMD", 0x01: "HCI_EVT", 0x02: "ACL_TX", 0x03: "ACL_RX",
    0x08: "SCO_TX", 0x09: "SCO_RX", 0x0A: "LMP_TX", 0x0B: "LMP_RX",
    0xF7: "SYSLOG", 0xF8: "KERNEL", 0xF9: "KDEBUG", 0xFA: "ERROR",
    0xFB: "POWER", 0xFC: "NOTE", 0xFD: "CONFIG", 0xFE: "NEW_CTRL",
}

ATT_OPS = {
    0x01: "ERROR_RSP", 0x02: "MTU_REQ", 0x03: "MTU_RSP",
    0x04: "FIND_INFO_REQ", 0x05: "FIND_INFO_RSP",
    0x06: "FIND_BY_TYPE_REQ", 0x07: "FIND_BY_TYPE_RSP",
    0x08: "READ_BY_TYPE_REQ", 0x09: "READ_BY_TYPE_RSP",
    0x0A: "READ_REQ", 0x0B: "READ_RSP",
    0x0C: "READ_BLOB_REQ", 0x0D: "READ_BLOB_RSP",
    0x0E: "READ_MULTI_REQ", 0x0F: "READ_MULTI_RSP",
    0x10: "READ_BY_GROUP_REQ", 0x11: "READ_BY_GROUP_RSP",
    0x12: "WRITE_REQ", 0x13: "WRITE_RSP",
    0x16: "PREPARE_WRITE_REQ", 0x17: "PREPARE_WRITE_RSP",
    0x18: "EXECUTE_WRITE_REQ", 0x19: "EXECUTE_WRITE_RSP",
    0x1B: "NOTIFICATION", 0x1D: "INDICATION", 0x1E: "CONFIRMATION",
    0x52: "WRITE_CMD", 0xD2: "SIGNED_WRITE_CMD",
}

KNOWN_UUIDS = {
    "1800": "Generic Access", "1801": "Generic Attribute", "180a": "Device Information",
    "180f": "Battery", "2a00": "Device Name", "2a01": "Appearance", "2a05": "Service Changed",
    "2a19": "Battery Level", "2a24": "Model Number", "2a25": "Serial Number",
    "2a26": "Firmware Revision", "2a27": "Hardware Revision", "2a28": "Software Revision",
    "2a29": "Manufacturer Name", "2a50": "PnP ID", "2803": "Characteristic Declaration",
    "2800": "Primary Service", "2801": "Secondary Service", "2902": "CCCD", "2901": "User Description",
    "6e400001-b5a3-f393-e0a9-e50e24dcca9e": "Nordic UART Service",
    "6e400002-b5a3-f393-e0a9-e50e24dcca9e": "NUS RX (write)",
    "6e400003-b5a3-f393-e0a9-e50e24dcca9e": "NUS TX (notify)",
}


def hexs(b: bytes) -> str:
    return " ".join(f"{x:02x}" for x in b)


def uuid_str(raw: bytes) -> str:
    """raw is little-endian 2 or 16 bytes."""
    if len(raw) == 2:
        return f"{struct.unpack('<H', raw)[0]:04x}"
    if len(raw) == 16:
        be = raw[::-1].hex()
        return f"{be[0:8]}-{be[8:12]}-{be[12:16]}-{be[16:20]}-{be[20:32]}"
    return raw.hex()


def uuid_label(u: str) -> str:
    name = KNOWN_UUIDS.get(u)
    return f"{u} ({name})" if name else u


# --------------------------------------------------------------------------- pklg


def read_records(path: str):
    data = open(path, "rb").read()
    n = len(data)
    if n < 13:
        return
    be_len = struct.unpack_from(">I", data, 0)[0]
    le_len = struct.unpack_from("<I", data, 0)[0]
    # Heuristic from Wireshark: whichever byte order gives a sane first record length.
    little = not (9 <= be_len <= n) or (9 <= le_len <= n and le_len < be_len and be_len > 0x100000)
    fmt = "<IIIB" if little else ">IIIB"
    off = 0
    while off + 13 <= n:
        length, secs, usecs, ptype = struct.unpack_from(fmt, data, off)
        end = off + 4 + length
        if length < 9 or end > n:
            break
        payload = data[off + 13:end]
        off = end
        yield secs + usecs / 1e6, ptype, payload


# --------------------------------------------------------------------------- ATT


class Decoder:
    def __init__(self):
        self.handle_uuid = {}       # handle -> uuid string
        self.char_value_handles = {}  # value handle -> (char uuid)
        self.services = []          # (start, end, uuid)
        self.pending_read_by_type = {}   # (conn, dir) -> uuid16 requested
        self.pending_read_handle = {}    # conn -> handle for READ_REQ awaiting RSP
        self.events = []
        self.reasm = {}             # (conn, dir) -> [expected_len, bytearray]
        self.t0 = None

    # ---- ACL / L2CAP

    def feed_acl(self, ts, direction, payload):
        if len(payload) < 4:
            return
        handle_flags, dlen = struct.unpack_from("<HH", payload, 0)
        conn = handle_flags & 0x0FFF
        pb = (handle_flags >> 12) & 0x3
        body = payload[4:4 + dlen]
        key = (conn, direction)
        if pb in (0b00, 0b10):  # first fragment
            if len(body) < 4:
                return
            l2len, cid = struct.unpack_from("<HH", body, 0)
            self.reasm[key] = [4 + l2len, cid, bytearray(body)]
        elif pb == 0b01:  # continuation
            if key not in self.reasm:
                return
            self.reasm[key][2] += body
        else:
            return
        expected, cid, buf = self.reasm[key]
        if len(buf) >= expected:
            del self.reasm[key]
            if cid == 0x0004:  # ATT
                self.feed_att(ts, direction, conn, bytes(buf[4:expected]))

    # ---- ATT

    def label(self, handle):
        u = self.handle_uuid.get(handle)
        if u is None:
            return f"h=0x{handle:04x}"
        return f"h=0x{handle:04x} {uuid_label(u)}"

    def emit(self, ts, direction, conn, op, handle=None, value=None, note=None):
        if self.t0 is None:
            self.t0 = ts
        self.events.append({
            "t": round(ts - self.t0, 4),
            "abs": ts,
            "dir": direction,
            "conn": conn,
            "op": ATT_OPS.get(op, f"0x{op:02x}"),
            "handle": handle,
            "uuid": self.handle_uuid.get(handle) if handle is not None else None,
            "hex": hexs(value) if value is not None else None,
            "note": note,
        })

    def feed_att(self, ts, direction, conn, pdu):
        if not pdu:
            return
        op = pdu[0]
        body = pdu[1:]
        try:
            if op == 0x08 and len(body) >= 6:  # READ_BY_TYPE_REQ
                self.pending_read_by_type[conn] = uuid_str(body[4:])
                self.emit(ts, direction, conn, op, note=f"type {uuid_label(uuid_str(body[4:]))}")
            elif op == 0x09 and len(body) >= 1:  # READ_BY_TYPE_RSP
                each = body[0]
                requested = self.pending_read_by_type.get(conn)
                i = 1
                notes = []
                while i + each <= len(body):
                    handle = struct.unpack_from("<H", body, i)[0]
                    value = body[i + 2:i + each]
                    if requested == "2803" and len(value) >= 5:  # characteristic declaration
                        props = value[0]
                        vhandle = struct.unpack_from("<H", value, 1)[0]
                        cuuid = uuid_str(value[3:])
                        self.handle_uuid[handle] = "2803"
                        self.handle_uuid[vhandle] = cuuid
                        self.char_value_handles[vhandle] = cuuid
                        notes.append(f"char {uuid_label(cuuid)} value h=0x{vhandle:04x} props=0x{props:02x}")
                    else:
                        notes.append(f"h=0x{handle:04x} = {hexs(value)}")
                    i += each
                self.emit(ts, direction, conn, op, note="; ".join(notes))
            elif op == 0x10 and len(body) >= 6:  # READ_BY_GROUP_REQ
                self.emit(ts, direction, conn, op, note=f"group {uuid_label(uuid_str(body[4:]))}")
            elif op == 0x11 and len(body) >= 1:  # READ_BY_GROUP_RSP
                each = body[0]
                i = 1
                notes = []
                while i + each <= len(body):
                    start, end = struct.unpack_from("<HH", body, i)
                    suuid = uuid_str(body[i + 4:i + each])
                    self.services.append((start, end, suuid))
                    self.handle_uuid[start] = "2800"
                    notes.append(f"service {uuid_label(suuid)} h=0x{start:04x}-0x{end:04x}")
                    i += each
                self.emit(ts, direction, conn, op, note="; ".join(notes))
            elif op == 0x05 and len(body) >= 1:  # FIND_INFO_RSP
                fmt = body[0]
                size = 2 if fmt == 1 else 16
                i = 1
                notes = []
                while i + 2 + size <= len(body):
                    handle = struct.unpack_from("<H", body, i)[0]
                    u = uuid_str(body[i + 2:i + 2 + size])
                    self.handle_uuid.setdefault(handle, u)
                    notes.append(f"h=0x{handle:04x} {uuid_label(u)}")
                    i += 2 + size
                self.emit(ts, direction, conn, op, note="; ".join(notes))
            elif op == 0x0A and len(body) >= 2:  # READ_REQ
                handle = struct.unpack_from("<H", body, 0)[0]
                self.pending_read_handle[conn] = handle
                self.emit(ts, direction, conn, op, handle=handle)
            elif op == 0x0B:  # READ_RSP
                handle = self.pending_read_handle.pop(conn, None)
                self.emit(ts, direction, conn, op, handle=handle, value=body)
            elif op in (0x12, 0x52, 0xD2, 0x1B, 0x1D) and len(body) >= 2:
                handle = struct.unpack_from("<H", body, 0)[0]
                self.emit(ts, direction, conn, op, handle=handle, value=body[2:])
            elif op == 0x16 and len(body) >= 4:  # PREPARE_WRITE_REQ
                handle, offset = struct.unpack_from("<HH", body, 0)
                self.emit(ts, direction, conn, op, handle=handle, value=body[4:], note=f"offset {offset}")
            elif op == 0x01 and len(body) >= 4:  # ERROR_RSP
                req, handle, code = struct.unpack_from("<BHB", body, 0)
                self.emit(ts, direction, conn, op, handle=handle, note=f"for {ATT_OPS.get(req, hex(req))} code 0x{code:02x}")
            elif op in (0x02, 0x03) and len(body) >= 2:
                self.emit(ts, direction, conn, op, note=f"mtu {struct.unpack_from('<H', body, 0)[0]}")
            else:
                self.emit(ts, direction, conn, op, value=body)
        except struct.error:
            self.emit(ts, direction, conn, op, value=body, note="(truncated)")


# --------------------------------------------------------------------------- main


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pklg")
    ap.add_argument("--json", action="store_true", help="emit JSON lines instead of text")
    ap.add_argument("--handles", action="store_true", help="only print the handle → UUID map")
    ap.add_argument("--all", action="store_true", help="include discovery/MTU traffic (default: data only)")
    ap.add_argument("--notes", action="store_true", help="also print PacketLogger NOTE/ERROR records")
    args = ap.parse_args()

    dec = Decoder()
    notes = []
    for ts, ptype, payload in read_records(args.pklg):
        if ptype == 0x02:
            dec.feed_acl(ts, "->", payload)
        elif ptype == 0x03:
            dec.feed_acl(ts, "<-", payload)
        elif ptype in (0xFA, 0xFC, 0xF7) and args.notes:
            notes.append((ts, PKT_TYPES[ptype], payload.decode("utf-8", "replace").strip()))

    if args.handles:
        for start, end, u in dec.services:
            print(f"service 0x{start:04x}-0x{end:04x}  {uuid_label(u)}")
        for h in sorted(dec.handle_uuid):
            print(f"  h=0x{h:04x}  {uuid_label(dec.handle_uuid[h])}")
        return

    data_ops = {"READ_REQ", "READ_RSP", "WRITE_REQ", "WRITE_RSP", "WRITE_CMD", "SIGNED_WRITE_CMD",
                "NOTIFICATION", "INDICATION", "CONFIRMATION", "PREPARE_WRITE_REQ", "EXECUTE_WRITE_REQ", "ERROR_RSP"}
    events = dec.events if args.all else [e for e in dec.events if e["op"] in data_ops]

    if args.json:
        for e in events:
            print(json.dumps(e))
        return

    if notes:
        for ts, kind, text in notes:
            when = dt.datetime.fromtimestamp(ts).strftime("%H:%M:%S.%f")[:-3]
            print(f"{when}  {kind:8}  {text}")
        print()

    for e in events:
        when = dt.datetime.fromtimestamp(e["abs"]).strftime("%H:%M:%S.%f")[:-3]
        parts = [when, f"{e['t']:+9.3f}s", e["dir"], f"{e['op']:<17}"]
        if e["handle"] is not None:
            parts.append(dec.label(e["handle"]))
        if e["hex"] is not None:
            parts.append(f"[{len(e['hex'].split()) if e['hex'] else 0}] {e['hex']}")
        if e["note"]:
            parts.append(e["note"])
        print("  ".join(parts))

    print(f"\n{len(events)} events, {len(dec.services)} services, {len(dec.char_value_handles)} characteristics", file=sys.stderr)


if __name__ == "__main__":
    main()
