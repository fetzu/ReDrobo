#!/usr/bin/env python3
### [   decode-esa || turns a droboesa capture into decoded ESA records   ] ###
## [ Field offsets confirmed against a live Drobo 5D, firmware 4.2.3 ]
"""
Usage: decode-esa.py <capture.log> [--raw] [--scan]

  Arguments:
    capture.log       A log produced by tools/droboesa/run-esa-capture.sh

  Options:
    --raw             Also hexdump the valid part of each record
    --scan            Brute force every u16/u32/u64 in range, for finding
                      fields we have not identified yet
"""

import re
import struct
import sys
import datetime

## [ CONSTANTS are the new vars ]

VERSION = "0.2.0"
TiB = 1024 ** 4
STRUCT_SIZE = 1308          # checkStructureOutputSize on kext selector 2
HDR = 4                     # 7a <subpage> <len hi> <len lo>

RECORD_NAMES = {
    0x01: "ConfigInfo", 0x02: "CapacityInfo", 0x03: "SlotInfo",
    0x04: "LunInfo", 0x05: "SystemSettings", 0x06: "ProtocolVersion",
    0x08: "FirmwareInfo", 0x09: "StatusInfo", 0x30: "Options",
    0x31: "Options2",
}

## [ FILE HANDLING FUNCTIONS ]

def parse_log(path):
    """
    Rebuild each record's 1308 byte buffer from the hexdump. droboesa collapses
    all-zero lines, so we place each line by its printed offset and leave the
    gaps as zeroes, which is what they were.
    """
    records, cur = {}, None
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"\s*--- record 0x([0-9a-f]{2})", line)
        if m:
            cur = int(m.group(1), 16)
            records[cur] = bytearray(STRUCT_SIZE)
            continue
        if cur is None:
            continue
        # NOTE: hexdump puts a double space after byte 7, so allow runs of spaces
        m = re.match(r"\s*([0-9a-f]{4})\s+((?:[0-9a-f]{2}[ ]+){1,16})\|", line)
        if m:
            off = int(m.group(1), 16)
            data = bytes.fromhex(re.sub(r"\s+", "", m.group(2)))
            records[cur][off:off + len(data)] = data
    return records

## [ Some custom FUNCTIONS ]

def u8(b, o):  return b[o]
def u16(b, o): return struct.unpack_from(">H", b, o)[0]
def u32(b, o): return struct.unpack_from(">I", b, o)[0]
def u64(b, o): return struct.unpack_from(">Q", b, o)[0]

def human(n):
    """Drobo Dashboard labels TiB as TB, so match that and show both."""
    return f"{n:,} bytes ({n / TiB:.2f} TiB)"

def ascii_at(b, o, n):
    """Fixed width text field, space and NUL padded."""
    return b[o:o + n].split(b"\x00")[0].decode("latin-1").strip()

def hexdump(b, start, end, indent="      "):
    for i in range(start, end, 16):
        chunk = bytes(b[i:min(i + 16, end)])
        hx = " ".join(f"{c:02x}" for c in chunk).ljust(47)
        txt = "".join(chr(c) if 0x20 <= c < 0x7f else "." for c in chunk)
        print(f"{indent}{i:04x}  {hx}  |{txt}|")

## [ The decoders, one per record ]
##
## Offsets below are NOT guesses. They come from the kext's own field reads in
## getESAModePage (movzbl 0x4(%r15), movq 0xc(%r15) and friends), cross checked
## against what Dashboard displayed at capture time.
##
## One catch: the kext reads those fields with x86 little endian loads, so its
## IOLog lines print nonsense for anything wider than a byte. The wire data is
## big endian, as SCSI should be. Trust the offsets, not Drobo's debug output.

def dec_config(b, plen):
    print(f"      slots   @0x04 u8   {u8(b, 4)}")
    print(f"      maxLuns @0x06 u8   {u8(b, 6)}")

def dec_capacity(b, plen):
    free, used, total = u64(b, 4), u64(b, 12), u64(b, 20)
    print(f"      free    @0x04 u64  {human(free)}")
    print(f"      used    @0x0c u64  {human(used)}")
    print(f"      total   @0x14 u64  {human(total)}")
    ok = "consistent" if free + used == total else "DOES NOT ADD UP"
    print(f"      check              free + used == total : {ok}")

def dec_lun(b, plen):
    print(f"      luns    @0x04 u8   {u8(b, 4)}")
    print(f"      total   @0x08 u64  {human(u64(b, 8))}")
    print(f"      used    @0x10 u64  {human(u64(b, 16))}")

def dec_slots(b, plen):
    """Slot count at 0x04, then that many 72 byte entries starting at 0x05."""
    n = u8(b, 4)
    print(f"      slots   @0x04 u8   {n}, then {n} entries of 72 bytes from 0x05")
    for i in range(n):
        base = 5 + i * 72
        cap = u64(b, base + 3)
        text = b[base + 20:base + 72].decode("latin-1")
        model = re.sub(r"\s+", " ", text.split("SATA")[0]).strip()
        role = "mSATA accelerator" if cap < 500 * 10**9 else f"bay {i + 1}"
        print(f"        slot {i} @0x{base:03x}  {role:<18} {cap / 10**12:>5.1f} TB"
              f"  {cap:>15,}  {model}")

def dec_system(b, plen):
    """
    The u32 holds the enclosure's LOCAL wall clock, not UTC, with the offset
    kept separately. Confirmed on 2026-08-19: the device read 16:19:07 while
    real UTC was 14:19:08, on a machine set to UTC+2. So format it in UTC to
    print the clock face the enclosure itself believes in.
    """
    t, off_min = u32(b, 4), u16(b, 8)
    when = datetime.datetime.fromtimestamp(t, datetime.timezone.utc)
    print(f"      time    @0x04 u32  {t} = {when:%Y-%m-%d %H:%M:%S} device local time")
    print(f"      gmtoff  @0x08 u16  {off_min} min = UTC{off_min // 60:+d}")
    print(f"      name    @0x0a str  {ascii_at(b, 10, 32)!r}")

def dec_protocol(b, plen):
    print(f"      version @0x04 u8.u8  {u8(b, 4)}.{u8(b, 5)}")

def dec_firmware(b, plen):
    print(f"      major   @0x04 u8   {u8(b, 4)}")
    print(f"      minor   @0x05 u8   {u8(b, 5)}")
    print(f"      build   @0xce u32  {u32(b, 206)}")
    print(f"        note: the kext logs u16@0x06 = {u16(b, 6)} as 'BuildNumber',")
    print(f"        which is just the low 16 bits of {u32(b, 206)}. Drobo's own")
    print(f"        debug line was truncating it.")
    print(f"      built   @0x0a str  {ascii_at(b, 10, 24)!r}")
    print(f"      platform      str  {ascii_at(b, 42, 16)!r}")
    print(f"      version       str  {ascii_at(b, 58, 8)!r}")

def dec_status(b, plen):
    print(f"      status  @0x04 u32  0x{u32(b, 4):08x}")
    print(f"      relayout@0x08 u32  {u32(b, 8)}")

def dec_options(b, plen):
    print(f"      yellowThreshold @0x04 u8  {u8(b, 4)} %")

def dec_options2(b, plen):
    v = u64(b, 4)
    print(f"      featureOnOffStates @0x04 u64  0x{v:016x} ({v})")

DECODERS = {
    0x01: dec_config, 0x02: dec_capacity, 0x03: dec_slots, 0x04: dec_lun,
    0x05: dec_system, 0x06: dec_protocol, 0x08: dec_firmware,
    0x09: dec_status, 0x30: dec_options, 0x31: dec_options2,
}

# Records 0x30 and 0x31 come back with a page length field that cannot be right
# (2304 and 64513 for a 1308 byte struct). Their payloads decode fine at the
# kext's fixed offsets, so do not let the bogus length stop us.
LENGTH_UNRELIABLE = {0x30, 0x31}

## [ MAIN ]

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    want_raw = "--raw" in sys.argv
    want_scan = "--scan" in sys.argv

    recs = parse_log(path)
    print(f"decode-esa {VERSION} -- {len(recs)} records from {path}\n")

    for pg in sorted(recs):
        b = recs[pg]
        name = RECORD_NAMES.get(pg, "?")
        plen = u16(b, 2)
        sane = b[0] == 0x7A and (pg in LENGTH_UNRELIABLE
                                 or 0 < plen <= STRUCT_SIZE - HDR)

        print(f"--- 0x{pg:02x} {name} ---")
        note = "ok"
        if pg in LENGTH_UNRELIABLE:
            note = "length field unreliable for this record, offsets still good"
        elif not sane:
            note = "SUSPECT"
        print(f"      header        {b[0]:#04x} {b[1]:#04x}, page length {plen}   {note}")

        if not sane:
            dec_unknown_len(b, plen)
            print()
            continue

        dec = DECODERS.get(pg)
        if dec:
            dec(b, plen)
        else:
            hexdump(b, HDR, HDR + plen)

        if want_raw and dec:
            print("      raw (valid range only):")
            hexdump(b, 0, HDR + plen)
        print()

    if want_scan:
        print("=== brute force scan, valid range only ===")
        for pg in sorted(recs):
            b = recs[pg]
            plen = u16(b, 2)
            if not (b[0] == 0x7A and 0 < plen <= STRUCT_SIZE - HDR):
                continue
            end = HDR + plen
            print(f"\n  --- 0x{pg:02x} {RECORD_NAMES.get(pg, '?')} ---")
            for o in range(HDR, end - 7):
                v = u64(b, o)
                if v > 10**9:
                    print(f"      @0x{o:03x} u64 {v:>20,}  ({v / TiB:.3f} TiB)")
    return 0

sys.exit(main())
