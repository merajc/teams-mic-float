#!/usr/bin/env python3
"""Talk to an Arduino over USB serial using only the macOS Python stdlib.

No pyserial needed. Works on macOS (uses termios B* constants).

Usage:
  python3 arduino-serial.py list
  python3 arduino-serial.py read  [--port auto] [--baud 115200] [--seconds 5]
  python3 arduino-serial.py send "V1 HELLO" [--port auto] [--baud 115200] [--wait 1.5]
  python3 arduino-serial.py watch [--port auto] [--baud 115200]

Notes:
  * Opening the port pulses DTR and RESETS an Uno/Nano. Expect a ~1s boot.
  * Prefer /dev/cu.* over /dev/tty.*. cu blocks until carrier, tty waits for DCD;
    cu is what every serial tool (screen, cu, arduino-cli) uses.
"""

import argparse
import glob
import os
import select
import subprocess
import sys
import termios
import time
import tty

BAUD_MAP = {
    1200: termios.B1200, 2400: termios.B2400, 4800: termios.B4800,
    9600: termios.B9600, 19200: termios.B19200, 38400: termios.B38400,
    57600: termios.B57600, 115200: termios.B115200, 230400: termios.B230400,
}


def usb_serials():
    """Return [(port, product_name, usb_serial)] for usbmodem-style ports."""
    found = []
    for port in sorted(glob.glob("/dev/cu.usb*")):
        found.append(port)
    return found


def describe_ports():
    """Best-effort map of /dev/cu.* to USB product names via ioreg."""
    ports = usb_serials()
    if not ports:
        print("No /dev/cu.usb* devices found.")
        print("Check the cable, the hub, and that a driver is installed for clones.")
        return 1

    labels = {}
    try:
        raw = subprocess.run(
            ["ioreg", "-p", "IOUSB", "-w0", "-l"],
            capture_output=True, text=True, timeout=10,
        ).stdout
        current = {}
        for line in raw.splitlines():
            line = line.strip()
            if line.startswith('"USB Product Name"'):
                current["product"] = line.split("=", 1)[1].strip().strip('"')
            elif line.startswith('"USB Serial Number"'):
                current["serial"] = line.split("=", 1)[1].strip().strip('"')
                if "product" in current:
                    labels[current["serial"]] = current["product"]
                current = {}
    except (subprocess.SubprocessError, OSError):
        pass

    for port in ports:
        name = ""
        for serial, product in labels.items():
            if serial and serial[-6:] in port:
                name = product
                break
        print(f"{port}" + (f"  ({name})" if name else ""))
    return 0


def resolve_port(requested):
    if requested and requested != "auto":
        return requested
    ports = usb_serials()
    if not ports:
        sys.exit("No /dev/cu.usb* port found. Is the board plugged in?")
    if len(ports) > 1:
        sys.exit("Multiple ports found; pass --port explicitly:\n  " + "\n  ".join(ports))
    return ports[0]


def open_port(port, baud):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    tty.setraw(fd)
    attrs = termios.tcgetattr(fd)
    # cflag: enable receiver, ignore modem control lines
    attrs[2] |= termios.CLOCAL | termios.CREAD
    attrs[4] = attrs[5] = BAUD_MAP[baud]
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def drain(fd, seconds):
    buf = b""
    end = time.time() + seconds
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            continue
        if chunk:
            buf += chunk
    return buf


def cmd_read(args):
    port = resolve_port(args.port)
    fd = open_port(port, args.baud)
    print(f"# {port} @ {args.baud} 8N1, reading {args.seconds}s", file=sys.stderr)
    data = drain(fd, args.seconds)
    os.close(fd)
    sys.stdout.write(data.decode("utf-8", "replace"))
    if data and not data.endswith(b"\n"):
        sys.stdout.write("\n")
    print(f"# {len(data)} bytes", file=sys.stderr)
    return 0


def cmd_send(args):
    port = resolve_port(args.port)
    fd = open_port(port, args.baud)
    payload = args.payload
    if not payload.endswith("\n"):
        payload += "\n"
    # Let the board finish booting after the DTR reset before writing.
    drain(fd, args.settle)
    os.write(fd, payload.encode())
    reply = drain(fd, args.wait)
    os.close(fd)
    print(f">>> {payload.strip()}")
    sys.stdout.write(reply.decode("utf-8", "replace") or "(no reply)\n")
    return 0


def cmd_watch(args):
    port = resolve_port(args.port)
    fd = open_port(port, args.baud)
    print(f"# watching {port} @ {args.baud}, Ctrl-C to stop", file=sys.stderr)
    try:
        while True:
            data = drain(fd, 1.0)
            if data:
                sys.stdout.write(data.decode("utf-8", "replace"))
                sys.stdout.flush()
    except KeyboardInterrupt:
        pass
    finally:
        os.close(fd)
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="list USB serial ports").set_defaults(func=lambda a: describe_ports())

    for name, func in (("read", cmd_read), ("send", cmd_send), ("watch", cmd_watch)):
        sp = sub.add_parser(name)
        sp.add_argument("--port", default="auto")
        sp.add_argument("--baud", type=int, default=115200, choices=sorted(BAUD_MAP))
        sp.set_defaults(func=func)
        if name == "read":
            sp.add_argument("--seconds", type=float, default=5.0)
        if name == "send":
            sp.add_argument("payload")
            sp.add_argument("--wait", type=float, default=2.5)
            sp.add_argument("--settle", type=float, default=2.0, help="drain time after the reset before sending")

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
