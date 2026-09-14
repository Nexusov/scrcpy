# Changes from scrcpy 4.0

Reconnection is enabled by the `SCRCPY_RECONNECT_SERIAL` environment variable,
which contains the ADB Wi-Fi device name of a previously paired phone.

## Implementation

Paths below are relative to `src/scrcpy/`.

- `app/src/scrcpy.c`: adds the reconnection loop and session cleanup while retaining
  the window; handles window closure while waiting for a connection.
- `app/src/screen.c` and `app/src/screen.h`: preserve the window, texture, and last
  frame; rebind device controls; block input until the first new frame; update the
  aspect ratio and restore mouse capture.
- `app/src/events.c` and `app/src/events.h`: resume processing main-thread tasks
  after the previous event producers have stopped.
- `app/src/server.c`: resolve the persistent mDNS name through ADB again before
  connecting over Wi-Fi.

## Validation

The following native baseline checks were completed before the launcher refactor:

- Windows x64 client build.
- Recovery after forcibly terminating the server for a test session.
- Preservation of the process ID and SDL window handle (HWND) across reconnection.
- Repeated reconnection.
- Window closure while the device address is unavailable.
- Launch without a console window.

Recovery after physically disconnecting USB was also manually confirmed on a POCO
phone running Android 16. Detailed local logs and device identifiers are excluded
from Git.

## First-run setup wizard

- `Settings.vbs` opens `launcher/setup.ps1`, which composes the settings session,
  runtime adapter, and Windows Forms view. Older `setup.vbs` entry points remain compatible.
- `launcher/launcher-core.ps1` handles service discovery, device identity, and pairing.
  Shared `adb-process.ps1` and `configuration-store.ps1` own process execution and
  persistence. Pairing codes are not saved.
- `launcher/launch.ps1` composes the connection controller and waiting window;
  `connection-core.ps1` preserves USB priority and selected connection mode.
- `scripts/package.ps1`: includes the wizard and shared helpers in portable ZIPs.

See [ARCHITECTURE.md](ARCHITECTURE.md) for current module boundaries, cancellation,
Retry generations, saved-state conflicts, and reset behavior.

Automated checks cover authorized/unauthorized devices, emulator/network device
exclusion, incorrect pairing, wrong-device discovery and identity, manual fallback,
legacy launch, USB priority, Wi-Fi launch, USB-only mode, cancellation, and ADB
process timeouts. Run them on Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\test.ps1
```

These tests use disposable fake ADB/client executables. They do not replace a
physical USB-disconnection test on an Android phone. The native reconnection
client and its runtime DLLs are unchanged by the wizard update.

## Wi-Fi-only onboarding

The setup wizard can now pair without a USB device. It reads the phone serial
through the paired Wi-Fi connection and retains USB priority for future launches.
Automatic pairing requires an unambiguous advertisement; manual pairing and
connection endpoints must share the phone IP and use different ports. Regression
tests cover Wi-Fi-only discovery, manual setup, configuration persistence,
ambiguous advertisements, and accidental reuse of the pairing port.

## Connection modes and simpler startup

- Setup offers USB, Wi-Fi, and USB + Wi-Fi (recommended) as separate modes.
- USB mode hides pairing controls; Wi-Fi mode does not require a USB phone.
  Combined mode verifies both connections and keeps automatic fallback.
- Manual address fields are collapsed until requested.
- `ConnectionMode` is saved in `phone.json` and respected on every launch.
  Legacy settings infer automatic fallback when Wi-Fi was configured, or USB
  otherwise. Existing settings do not need to be edited or recreated.
- `Start.vbs` is the user-facing entry point. `launch.vbs` remains compatible
  with existing shortcuts; neither file installs the application.
