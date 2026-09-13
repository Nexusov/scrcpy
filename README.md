# scrcpy Seamless

A Windows fork of [scrcpy 4.0](https://github.com/Genymobile/scrcpy) that keeps
screen mirroring in the same window when switching from USB to Wi-Fi.

## Features

- **USB priority:** uses an authorized USB connection when available at startup.
- **Wi-Fi fallback:** reconnects over Wi-Fi when the USB connection is lost.
- **Persistent window:** keeps the last frame visible and displays `Reconnecting...`
  in the title while waiting for the phone.
- **Session recovery:** resumes video, audio, and device control in the same window.
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

1. Extract the portable package into a writable directory.
2. Copy `phone.example.json` to `phone.json` and configure your device.
3. Connect your phone over USB, enable **USB debugging**, and authorize your PC.
4. Enable **Wireless debugging** and pair the phone with your PC for Wi-Fi fallback.
5. Run `launch.vbs`.

### Requirements

- Windows x64, Windows PowerShell 5.1, and Windows Script Host.
- An authorized ADB connection and a USB driver for your phone, if required.
- A device meeting the upstream scrcpy Android requirements. Wireless debugging
  requires Android 11 or later.
- The phone and PC on the same network for Wi-Fi connectivity.

### Device configuration

Run these commands from the portable package directory:

```powershell
.\adb.exe devices
.\adb.exe pair PHONE_IP:PAIRING_PORT
.\adb.exe mdns services
```

Enter the pairing code when `adb pair` prompts for it. In `phone.json`, set:

| Field | Value |
| --- | --- |
| `UsbSerial` | The USB serial number reported by `adb devices` |
| `WirelessService` | The service name reported by `adb mdns services`, ending in `._adb-tls-connect._tcp` |

When both USB and the Wi-Fi service are available, the launcher automatically
refreshes the saved service name.

Device settings and logs are excluded from Git. For troubleshooting, check
`last-run.log` and `last-run-errors.log` in the application directory.

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
| `launcher/` | Launch scripts and an example device configuration |
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
