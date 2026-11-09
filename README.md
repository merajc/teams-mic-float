# Teams Mic Float

[![CI](https://github.com/merajc/teams-mic-float/actions/workflows/ci.yml/badge.svg)](https://github.com/merajc/teams-mic-float/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg)]()
[![Hardware](https://img.shields.io/badge/Hardware-Arduino%20Uno%20%2B%20MAX7219-brightgreen.svg)]()

A lightweight, zero-dependency native macOS menu bar & floating mute controller for Microsoft Teams. Features real-time bi-directional synchronization with Teams, flexible display modes (menu-bar only, in-call only, or floating circle), and an optional physical Arduino desk button with an 8x8 MAX7219 LED matrix status display.

![Floating button states](docs/states.png)

---

## Key Features

- **Zero-API Teams Integration**: Bypasses the retired local third-party WebSocket API using low-overhead macOS Accessibility UI automation.
- **Multiple Display Modes**:
  - **Menu Bar Only**: Completely hides the floating button, living unobtrusively in your macOS status bar with adaptive Dark/Light mode contrast.
  - **In-Call Only**: Automatically appears when a call starts and disappears when the meeting ends.
  - **Always Visible**: Persistent floating circular button with drag-and-drop repositioning.
- **Bi-Directional State Sync**: Toggling mute from Teams UI, Teams keyboard shortcuts (`Shift+Cmd+M`), the menu bar, the floating button, or the hardware desk button updates all indicators within ~150 ms.
- **Physical Desk Controller (Arduino Uno + MAX7219 8x8 LED Matrix)**:
  - Sub-15ms momentary push-button hardware toggle.
  - Visual status themes: Checkmark/Cross, Retro Mic, or Status Letters.
  - Native USB serial driver with zero external daemons or Python runtimes.
  - Seamless hot-plug recovery and auto-reconnect with Optiboot settle delay.
  - Built-in hardware ping/pong latency diagnostics.
- **Native macOS Experience**:
  - Launch at Login support via `SMAppService`.
  - Rebuild-safe code-signing preserving Accessibility permissions across builds.
  - Dark Mode-aware template status item.

---

## Why Accessibility?

Microsoft retired the local Teams third-party app API on **June 30, 2026** ([MC1266901](https://msmessagecenter.com/MC1266901)). The **Third-party app API** setting was removed from modern Teams clients, and local port `8124` is closed.

Commercial hardware solutions (such as MuteMe v0.27.2+) transitioned to macOS **Accessibility UI automation**. Teams Mic Float adopts this same robust approach:

- Meeting window detection: `Meeting compact view | …`, AX subrole `AXSystemDialog`.
- Microphone element: `AXDOMIdentifier = "microphone-button"`.
- Muted state: button title/description is **“Unmute mic”**.
- Unmuted state: button title/description is **“Mute mic”**.
- Mute action: dispatches native `AXPress`.

---

## Requirements

- **macOS 13 (Ventura) or later** (tested on macOS 14 & macOS 15+).
- **Microsoft Teams desktop client** (Work or School / New Teams).
- **macOS Accessibility Permission**:
  - On macOS 15+: **System Settings → Privacy & Security → Accessibility** (or **Device Control and Data Access**).
- *(Optional)* **Arduino Uno** with a momentary push-button and MAX7219 8x8 LED matrix display for physical desk control.

---

## Quick Start

### 1. Build and Run

```bash
git clone https://github.com/merajc/teams-mic-float.git
cd teams-mic-float

# Recreate stable signing identity (preserves permissions across rebuilds)
./scripts/setup_signing.sh

# Build native app bundle
./scripts/build_app.sh

# Launch the application
open dist/TeamsMicFloat.app
```

The app runs as an `LSUIElement` background agent with no Dock icon. Look for the microphone status icon in your macOS menu bar.

### 2. Grant Accessibility Permission

On first launch, if permissions have not been granted yet:
1. Click the menu-bar mic icon → **Accessibility Settings…** (or follow the system prompt).
2. Enable **TeamsMicFloat** in the list.
3. Teams Mic Float will detect the grant automatically; no restart required.

---

## Usage

### Menu Bar & Display Modes
Click the microphone icon in your Mac menu bar to access options:
- **Floating Button Menu**:
  - `Hide (Menu Bar Only)`: Hides the on-screen circle button completely.
  - `Show During Calls Only`: Automatically shows the floating button during active Teams meetings and hides it when idle.
  - `Show Always`: Keeps the draggable circle visible across desktops and spaces.
- **Launch at Login**: Toggle automatic startup when logging into your Mac.
- **Arduino Diagnostics…**: Tests USB serial latency and roundtrip ping/pong response.
- **Reconnect Arduino**: Manually resets and queries the serial connection if needed.

### Visual State Indicators

| Visual | Meaning | Menu Bar Color |
|---|---|---|
| Red, `MUTED`, `IN CALL` | In a call; Teams mic muted | Vibrant Red |
| Green, `UNMUTED`, `IN CALL` | In a call; microphone live | Vibrant Green |
| Grey, `IDLE`, `NO CALL` | Teams running, no active call | Adaptive System Contrast |
| Dark grey, `OFFLINE`, `NO TEAMS` | Teams not running | Adaptive System Contrast |
| Amber, `LINKING`, `CONNECTING` | Connecting to Teams UI tree | Warning Amber |
| Amber, `ACCESS`, `PERMISSION` | Accessibility permission needed | Warning Amber |
| Grey, `SYNC`, `IN CALL` | Call detected; restore window | Adaptive System Contrast |

---

## Arduino Hardware Desk Controller

Connect an Arduino Uno over USB to toggle mute from your desk and display live status on an 8x8 MAX7219 LED matrix.

```text
       +-------------------------------+
       |       Arduino Uno (R3)        |
       |                               |
       |     [Pin 10] ----------------> CLK (Orange)
       |     [Pin  9] ----------------> CS  (Yellow)   [MAX7219 8x8 LED Matrix]
       |     [Pin  8] ----------------> DIN (Green)
       |     [  5V  ] ----------------> VCC (Red)
       |     [  GND ] ----------------> GND (Brown)
       |                               |
       |     [Pin  2] ----[ Push  ]----+
       |     [  GND ] ----[ Button]----+ (Momentary tactile switch)
       +-------------------------------+
```

### Pinout Table

| Component | Component Pin | Wire Color | Arduino Uno Pin | Notes |
|---|---|---|---|---|
| **MAX7219 Matrix** | **VCC** | Red | **5V** | Power |
| **MAX7219 Matrix** | **GND** | Brown | **GND** | Ground |
| **MAX7219 Matrix** | **DIN** | Green | **Pin 8** | SPI Data In |
| **MAX7219 Matrix** | **CS / LOAD** | Yellow | **Pin 9** | Chip Select |
| **MAX7219 Matrix** | **CLK** | Orange | **Pin 10** | Clock |
| **Push Button** | Terminal 1 | Any | **Pin 2** | Uses internal `INPUT_PULLUP` (<15ms latency) |
| **Push Button** | Terminal 2 | Any | **GND** | Ground |

### Matrix Visual Themes

Select your preferred theme in [`arduino/teams_mic_button/teams_mic_button.ino`](arduino/teams_mic_button/teams_mic_button.ino) via `#define THEME_SELECTION`:

- **Theme 1**: Retro Microphone (Live) vs Slashed Microphone (Muted).
- **Theme 2**: Text Display (`ON` vs `M`).
- **Theme 3 (Default)**: Checkmark (Live) vs Giant Cross `X` (Muted).

### Flashing Firmware

Upload the sketch using `arduino-cli`:

```bash
# Release the serial port prior to upload
killall TeamsMicFloat

# Compile & flash
arduino-cli compile --fqbn arduino:avr:uno arduino/teams_mic_button
arduino-cli upload  --fqbn arduino:avr:uno -p /dev/cu.usbmodem* arduino/teams_mic_button

# Relaunch the app
open dist/TeamsMicFloat.app
```

---

## Project Structure

```text
Sources/TeamsMicFloat/
  main.swift                          # Entry point and CLI parsing
  AppDelegate.swift                   # Menu bar, status item, lifecycle, Launch at Login
  ArduinoSerialController.swift       # POSIX USB serial driver, auto-reconnect, ping/pong
  FloatingPanelController.swift       # Always-on-top non-activating NSPanel
  StatusView.swift                    # Custom button rendering, drag-to-move, click action
  TeamsAccessibilityController.swift  # Teams UI accessibility scanner & AXPress invoker
  TeamsProtocol.swift                 # State models, visual mappings, legacy parser
  TeamsClient.swift                   # Legacy WebSocket client (optional reference)
  ConfigStore.swift                   # JSON configuration and window-position persistence
  ToastController.swift               # Permission alerts and system toasts
  AppOptions.swift                    # CLI argument parsing
arduino/
  teams_mic_button/
    teams_mic_button.ino              # Arduino Uno firmware (MAX7219 + button debounce)
Tests/
  TestHarness.swift                   # Dependency-free native Swift test suite
scripts/
  build_app.sh                        # Assembles and codesigns dist/TeamsMicFloat.app
  run.sh                              # Helper launch script
  run_tests.sh                        # Compiles and executes native test harness
  setup_signing.sh                    # Generates local self-signed certificate keychain
```

---

## Testing

Run the native test harness:

```bash
./scripts/run_tests.sh
```

All 80 checks run dependency-free and validate:
- State machine transitions & visual mappings.
- Teams AX DOM identifier and title parsing.
- Configuration persistence, security permissions (`0600`), and auto-healing.
- Action frame parsing and WebSocket legacy protocol fallback.

---

## Troubleshooting

- **Icon Hard to See in Menu Bar**: The menu bar icon uses native macOS template rendering. It automatically adapts to dark or light themes when idle, and turns vivid red/green when in an active call.
- **Accessibility Permission Prompts Again After Rebuilding**: Run `./scripts/setup_signing.sh` before `./scripts/build_app.sh`. Using a consistent local signing identity ensures macOS recognizes the bundle across builds without resetting privacy permissions.
- **Arduino Not Detected**: Ensure the board is connected via a data-capable USB cable. Test with Menu Bar → **Arduino Diagnostics…** or check `/dev/cu.usbmodem*`.

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
