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

The following checks were completed:

- Windows x64 client build.
- Recovery after forcibly terminating the server for a test session.
- Preservation of the process ID and SDL window handle (HWND) across reconnection.
- Repeated reconnection.
- Window closure while the device address is unavailable.
- Launch without a console window.

Recovery after physically disconnecting USB was also manually confirmed on a POCO
phone running Android 16. Detailed local logs and device identifiers are excluded
from Git.
