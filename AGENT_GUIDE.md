# Arduino on this Mac: agent instructions

Practical notes for any agent asked to talk to the Arduino on this machine.
Everything here was verified on 2026-11-09 against the board currently attached.

## 1. Detect what is plugged in

```bash
ls /dev/cu.*                      # serial ports; Arduino shows as /dev/cu.usbmodem*
ioreg -p IOUSB -w0 -l | grep -E 'USB Product Name|USB Vendor Name|USB Serial Number'
system_profiler SPUSBDataType    # can return empty on some macOS versions; use ioreg
lsof /dev/cu.usbmodem11301       # is another process holding the port?
```

Board currently attached:

| Field | Value |
| --- | --- |
| Port | `/dev/cu.usbmodem11301` |
| Product | Arduino Uno (VID `0x2341`, PID `0x0043`) |
| USB serial | `12150481010698122650` |
| Path | Uno -> Dell DA310 hub -> Frescologic USB2 hub -> Mac |

Port names are not stable. They change when you move the cable to a different port
or hub. Always rediscover with `ls /dev/cu.usb*`; never hardcode.

## 2. Read and write the serial port

`pyserial` and `serialport` are **not** installed. Use the stdlib helper in this
folder.

```bash
python3 arduino-serial.py list                    # ports plus product names
python3 arduino-serial.py read --seconds 5        # capture output
python3 arduino-serial.py send "V1 HELLO"         # write a line, print the reply
python3 arduino-serial.py watch                   # follow output, Ctrl-C to stop
```

**Do not use the `stty` + shell redirection route on this board.** It looks like it
works and doesn't. Verified:

```bash
stty -f /dev/cu.usbmodem11301 115200 cs8 -cstopb -parenb raw   # exit 0
stty -f /dev/cu.usbmodem11301 -a | head -1
# => speed 9600 baud     (the 115200 was silently ignored)
```

With the line stuck at 9600, `cat`/`printf` against the port produced binary garbage,
not the firmware's ASCII. The Python helper sets the baud through `termios` and works
every time. If you must stay in the shell, use a tool that does the ioctl itself
(`arduino-cli monitor`) rather than `stty`. Untested here, but those tools set the
rate with an ioctl instead of parsing stty flags.

## 3. Gotchas that waste an hour

- **Opening the port resets the board.** Uno/Nano use a USB-serial chip that pulses
  DTR, so the sketch restarts. Wait ~1-2s before sending a command or the firmware
  eats it. The helper's `--settle` handles this.
- **Wrong baud looks like garbage, not silence.** Random binary bytes mean a baud
  mismatch. This board is **115200**. 9600 and 57600 both produced junk.
- **`/dev/cu.*`, not `/dev/tty.*`.** tty waits for DCD and will block.
- **One owner at a time.** Two readers on the same port gives both of them partial
  data. Check with `lsof` before assuming the board is dead.
- **Clones need a driver.** Genuine Arduino VID `0x2341` works with no driver. A
  CH340 clone (VID `0x1a86`) needs the WCH driver, a CP2102 clone (VID `0x10c4`)
  the Silicon Labs driver. If nothing enumerates, that is the likely reason.
- **No reset switch on the Uno.** If it hangs, opening the port is your reset.

## 4. Flashing code

Nothing is installed yet: no `arduino-cli`, no `avrdude`, no Arduino IDE.

```bash
brew install arduino-cli
arduino-cli core update-index
arduino-cli core install arduino:avr
arduino-cli board list                       # confirm port + FQBN
arduino-cli compile --fqbn arduino:avr:uno my_sketch
arduino-cli upload  --fqbn arduino:avr:uno -p /dev/cu.usbmodem11301 my_sketch
arduino-cli monitor -p /dev/cu.usbmodem11301 -c baudrate=115200
```

FQBN for this board: `arduino:avr:uno`.

Ask before uploading. Upload erases whatever sketch is on the board, and this board
is currently running firmware that is not in this repo.

## 5. What this board is actually running

It is not a blank Uno. A sketch answers at 115200 with a line protocol:

```
V1 READY fw=0.2.0-matrix proto=1 display=max7219 intensity=0 buzzer=disabled
V1 DIAG startup=row_scan host_grace_ms=15000 timeout_ms=30000
V1 STATUS state=OFF display=OFF gen=0 ack=0 silence=0 stale=0
```

Observed behaviour:

- `V1 HELLO` -> `READY` banner, then `STATUS`.
- `V1 GET` -> `STATUS` only.
- `V1 PING <n>` -> `V1 PONG seq=<n>`. A missing or non-numeric sequence gives
  `ERR code=BAD_FORMAT detail=use_V1_PING_sequence`. This is the only round-trip
  verified end to end.
- `V1 SET <state> <generation>` is the expected shape, per the error hint
  `use_V1_SET_state_generation`. **Unverified**: my attempts (`SET ON`, `SET 1 7`)
  produced no error and no state change (`state=OFF gen=0` before and after).
  Treat SET semantics as unknown; do not report it as working.
- Unknown verbs reply `ERR code=UNKNOWN_COMMAND detail=supported_HELLO_PING_SET_GET_RESET`.
- `RESET` takes no arguments (`RESET_has_extra_fields` otherwise). Not tested —
  assumed to clear state, so try it only with the user's go-ahead.
- The firmware mentions a 15s host grace and 30s timeout. Something changes when a
  host stops talking. Do not leave a long-running monitor attached unless you want
  the board to see a live host.

## 6. Rules for agents

1. **Read before writing.** Capture the banner first so you know the baud and the protocol.
2. **Do not guess protocols and call it done.** Unknown SET semantics is a known gap, not a success.
3. **No uploads without approval.** Flashing destroys the running sketch.
4. **No `RESET`, no state changes** on hardware the user is actively using without asking.
5. **Report the port path you used** in any result, since it changes between sessions.
