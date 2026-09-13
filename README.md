# scrcpy Seamless

A Windows fork of [scrcpy 4.0](https://github.com/Genymobile/scrcpy) that keeps
screen mirroring in the same window when switching from USB to Wi-Fi.

## Features

- **USB priority:** uses an authorized USB connection when available at startup.
- **Wi-Fi fallback:** reconnects over Wi-Fi when the USB connection is lost.
- **Persistent window:** keeps the last frame visible and displays `Reconnecting...`
  in the title while waiting for the phone.
- **Session recovery:** resumes video, audio, and device control in the same window.
- **Guided setup:** detects your USB phone and configures Wi-Fi in a desktop wizard.
- **USB-only mode:** start mirroring without setting up Wi-Fi.
- **Quiet launcher:** starts without a separate console window.

Closing the window stops reconnection attempts. Switching back from Wi-Fi to USB
requires restarting the application.

This is an independent modification, not an official [Genymobile](https://github.com/genymobile) release.
Upstream copyright notices and licensing are preserved.

## Getting started

Download the portable ZIP from the [latest release](https://github.com/Nexusov/scrcpy/releases/latest).
The release also includes checksums and a separate dependency source archive.

These instructions apply to a prepared Windows x64 portable package. The source
repository does not include the runtime binaries; see the [build guide](docs/BUILD.md)
to build and package the application.

1. Extract the portable package into a writable directory and run `launch.vbs`.
2. On your phone, enable **Developer options** and **USB debugging**. Connect it
   by USB, unlock it, and accept the authorization prompt.
3. In the setup window, click **Refresh** if necessary and select your phone.
4. Choose **Use USB only** to start immediately, or configure Wi-Fi below.

For automatic USB-to-Wi-Fi reconnection, keep the phone and PC on the same
network. On the phone, enable **Wireless debugging** and open **Pair device with
pairing code**. Enter the six-digit code in the wizard and click **Pair and finish**.
The wizard detects the address when possible, verifies the Wi-Fi device, and
saves the configuration. Mirroring starts after setup completes.

No terminal commands or manual JSON editing are required. On subsequent launches,
run `launch.vbs` or your shortcut. Existing valid settings are reused automatically.
To change phones or enable Wi-Fi later, run `setup.vbs`, then restart mirroring.
Cancelling setup leaves existing settings unchanged.

### Requirements

- Windows x64, Windows PowerShell 5.1, and Windows Script Host.
- An authorized ADB connection and a USB driver for your phone, if required.
- A device meeting the upstream scrcpy Android requirements. Wireless debugging
  requires Android 11 or later.
- The phone and PC on the same network for Wi-Fi connectivity.

### If automatic Wi-Fi discovery fails

Keep the pairing-code dialog open. Enter its **IP address and pairing port** in
**Pairing IP:port**, then enter the current pairing code again.

If the paired phone still cannot be discovered, also enter **Connection IP:port**
from the main **Wireless debugging** screen. The connection port is different
from the pairing port. Both addresses must refer to the same phone IP. The wizard
verifies the phone over Wi-Fi before saving anything.

Manual addresses must use IPv4, for example `192.168.1.10:37000`. A saved manual
connection address may change when the phone reconnects to the network or
Wireless debugging restarts; rerun `setup.vbs` if it stops working. Automatically
discovered service names are refreshed when available.

### Settings and diagnostics

The wizard creates `phone.json` in the application directory. Advanced users can
still use `phone.example.json` as a reference: `UsbSerial` identifies the USB
phone; `WirelessService` contains its discovered ADB service or a manual connection
address. An empty `WirelessService` enables USB-only mode.

Keep the application in a writable folder. Device settings and logs are excluded
from release packages and Git. Check `last-run.log` and `last-run-errors.log` for
launch errors. Setup errors appear directly in the wizard; pairing codes are not
saved in the configuration.

## Limitations

Reconnection mode supports regular screen mirroring. Recording, session time
limits, and OTG/AOA are not supported in this mode. The portable build supports
USB mirroring and control through ADB; OTG is disabled at build time.

Device control is unavailable while disconnected. The window may briefly stop
responding while the previous session shuts down.

## Development

See the [build guide](docs/BUILD.md) for dependencies and build commands, and the
[change notes](docs/CHANGES.md) for implementation details and validation coverage.
Build tools and development headers are only required for building the application.

| Path | Purpose |
| --- | --- |
| `src/scrcpy/` | Complete scrcpy 4.0 source with reconnection changes |
| `launcher/` | Launch scripts, setup wizard, and shared device configuration helpers |
| `scripts/build.ps1` | Builds the client using separately installed tools |
| `scripts/package.ps1` | Creates a portable archive without personal settings or logs |
| `docs/BUILD.md` | Build and packaging instructions |
| `docs/CHANGES.md` | Reconnection implementation and validation notes |

`outputs/`, `work/`, `.build/`, and `dist/` are excluded from Git. Executables and
runtime DLLs belong in separate release archives rather than source history.

## License

scrcpy is licensed under [Apache-2.0](LICENSE). See [THIRD_PARTY.md](THIRD_PARTY.md)
for component provenance and dependency licensing information.

This software uses FFmpeg libraries under LGPL-2.1-or-later. Corresponding
[dependency sources](https://github.com/Nexusov/scrcpy/releases/latest) are provided
alongside the portable download. Third-party license notices are included in `licenses/`.
