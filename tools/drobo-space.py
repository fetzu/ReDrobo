#!/usr/bin/env python3
### [   drobo-space || real free space on a Drobo, on any Mac, no driver   ] ###
"""
Tells you how full the array actually is, on a Mac that has no Drobo Dashboard.

Why this is needed: a Drobo advertises a huge thin provisioned LUN, so the
filesystem on top believes it has terabytes of free space that do not exist.
A 5D holding a few real terabytes will cheerfully report a dozen free.

Why it works without a driver: macOS reports the *used* space correctly. Only
the array total is hidden behind the management channel, and that total only
changes when you add, remove or replace a disk. So cache the total once from a
real ESA capture and the arithmetic is right everywhere.

What it does not do: health, bay status, alerts, disk temperatures. Those need
the real driver. This just stops the array filling up behind your back.

Usage:
  drobo-space.py [--volume PATH] [--json] [--set-total BYTES]

Options:
  --volume PATH      Volume to check (default: whatever is in the config)
  --json             Machine readable output, for a menu bar or a cron job
  --set-total BYTES  Record a new array total, e.g. after changing a disk
"""

import argparse
import json
import os
import shutil
import sys

## [ CONSTANTS are the new vars ]

VERSION = "1.0.0"
CONFIG = os.path.expanduser("~/.config/redrobo/array.json")
TiB = 1024 ** 4

# There is nothing site specific baked in here. Record your own array total
# once with --set-total, taken from ESA record 0x02 offset 0x14 (see
# docs/PROTOCOL.md), or from what the ReDrobo app reports as the real size.
DEFAULTS = {
    "volume": None,                     # autodetected if not configured
    "total_bytes": 0,                   # must be set once, see --set-total
    "yellow_percent": 85,               # ESA Options record 0x30 @0x04
    "red_percent": 95,
    "captured": "never",
}

## [ FILE HANDLING FUNCTIONS ]

def load_config():
    """Config file wins over the built in defaults, so a disk swap is one edit."""
    cfg = dict(DEFAULTS)
    try:
        with open(CONFIG) as f:
            cfg.update(json.load(f))
    except FileNotFoundError:
        pass
    except (OSError, ValueError) as e:
        print(f"warning: ignoring unreadable {CONFIG} ({e})", file=sys.stderr)
    return cfg

def save_config(cfg):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG, "w") as f:
        json.dump(cfg, f, indent=2)
    print(f"Saved to {CONFIG}")

## [ Some custom FUNCTIONS ]

def autodetect_volume(total_bytes):
    """
    A Drobo advertises far more space than it has, so a mounted volume whose
    reported size is well above the real array total is almost certainly it.
    """
    import subprocess
    try:
        vols = os.listdir("/Volumes")
    except OSError:
        return None
    for name in vols:
        path = os.path.join("/Volumes", name)
        try:
            u = shutil.disk_usage(path)
        except OSError:
            continue
        if total_bytes and u.total > total_bytes + TiB:
            return path
    return None


def human(n):
    """Drobo labels TiB as TB, so show TiB and say so."""
    return f"{n / TiB:.2f} TiB"

def bar(pct, width=40):
    filled = min(width, int(round(pct / 100 * width)))
    return "[" + "#" * filled + "." * (width - filled) + "]"

## [ MAIN ]

def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--volume")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--set-total", type=int)
    ap.add_argument("-h", "--help", action="store_true")
    args = ap.parse_args()

    if args.help:
        print(__doc__)
        return 0

    cfg = load_config()

    if args.set_total is not None:
        cfg["total_bytes"] = args.set_total
        if args.volume:
            cfg["volume"] = args.volume
        save_config(cfg)
        return 0

    volume = args.volume or cfg["volume"] or autodetect_volume(cfg["total_bytes"])
    if not volume:
        print("No Drobo volume found. Name one with --volume /Volumes/Something",
              file=sys.stderr)
        return 1
    if not cfg["total_bytes"]:
        print("The array total is not configured yet. Set it once with:\n"
              "  drobo-space.py --set-total <bytes> --volume <path>\n"
              "Take the number from ESA record 0x02 offset 0x14, or from ReDrobo.",
              file=sys.stderr)
        return 2
    if not os.path.ismount(volume) and not os.path.isdir(volume):
        msg = f"{volume} is not mounted"
        print(json.dumps({"error": msg}) if args.json else f"xx  {msg}",
              file=sys.stderr)
        return 1

    # The filesystem's used figure is trustworthy. Its total and free are not.
    usage = shutil.disk_usage(volume)
    used = usage.used
    total = cfg["total_bytes"]
    free = total - used
    pct = used / total * 100

    if pct >= cfg["red_percent"]:
        state, note = "red", "act now, the array is nearly full"
    elif pct >= cfg["yellow_percent"]:
        state, note = "yellow", "past the Drobo's own warning threshold"
    else:
        state, note = "green", "healthy"

    if args.json:
        print(json.dumps({
            "volume": volume, "state": state,
            "used_bytes": used, "free_bytes": free, "total_bytes": total,
            "used_percent": round(pct, 2),
            "total_captured": cfg["captured"],
        }, indent=2))
        return 0

    colour = {"green": "\033[32m", "yellow": "\033[33m", "red": "\033[31m"}[state]
    print(f"drobo-space {VERSION}  --  {volume}")
    print()
    print(f"  {colour}{bar(pct)}\033[0m  {pct:.1f} %")
    print()
    print(f"  used   {human(used):>10}")
    print(f"  free   {human(free):>10}   <- the real number")
    print(f"  total  {human(total):>10}   (cached from {cfg['captured']})")
    print()
    print(f"  status {colour}{state.upper()}\033[0m, {note}")
    print()
    print(f"  For comparison, macOS thinks there is {human(usage.free)} free,")
    print(f"  because the Drobo advertises a thin provisioned LUN.")

    # NOTE: the cached total is only valid until the disk pack changes.
    return 0

sys.exit(main())
