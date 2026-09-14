# scrcpy Seamless

Mirror and control your Android phone on Windows. Connect by USB, Wi-Fi, or both;
when a USB connection drops, Wi-Fi fallback restores mirroring in the same window.

An independent fork of [scrcpy 4.0](https://github.com/Genymobile/scrcpy), not an
official [Genymobile](https://github.com/genymobile) release.

## Download and start

1. Open the [latest release](https://github.com/Nexusov/scrcpy/releases/latest) and
   download **`scrcpy-seamless-win64.zip`**. The dependency source archive and
   GitHub's **Source code** downloads are not needed to run the app.
2. Extract the ZIP into an empty folder where you can save files. Do not run it
   inside the archive or extract it over an older package.
3. Double-click **`Start.vbs`** and choose how to connect your phone in the setup
   wizard. Follow the instructions below for your preferred connection.
4. Leave **Create a desktop shortcut** selected if you want a desktop launcher.
   The shortcut is created after successful setup; an existing app shortcut is reused.

Mirroring starts when setup finishes. After that, use **`Start.vbs`** or your
shortcut to launch the app. No installation, terminal commands, or manual
configuration files are needed. Keep all extracted files together.

The ZIP contains `Start.vbs`, `Settings.vbs`, this README, `LICENSE`, and
`THIRD_PARTY.md` at the top level. Everything needed to run the app is inside
`app/`; do not move its files out individually. You can move the whole extracted
folder, then open Settings and use **Create shortcut now** to update your desktop shortcut.

To change the connection mode or phone later, run **`Settings.vbs`**, then restart
mirroring. Cancelling setup keeps your previous settings. Existing `launch.vbs`
shortcuts continue to work. Existing installations also retain `Setup.vbs` as a compatible entry point.

Settings loads your saved phone and connection mode. You can save changes without
repeating Wi-Fi pairing when a saved Wi-Fi configuration is available. Use
**Set up another phone** to configure another device. If the phone has forgotten this PC,
pair it again. Creating a shortcut does not require the phone to be connected.

## Reset device settings

Open **`Settings.vbs`** and choose **Reset device setup...** to remove the saved
phone and connection configuration. Close any running mirroring window first,
then confirm the reset. You can configure a phone again immediately or on the
next launch. If a connection window is already waiting, finish saving your new settings, then click **Retry now** in that window.

Reset keeps your desktop shortcut, logs, and shared ADB keys. It does not remove
pairing from the phone or affect other ADB applications. To forget this PC on the
phone as well, open **Wireless debugging > Paired devices**, select the PC, and
choose **Forget**.
## Connecting to your phone

A connection window appears immediately when you start the app. It shows what
your selected connection mode needs: USB authorization or Wireless debugging and
a shared network. After ten seconds, the status changes to **Still waiting for
your phone** while connection attempts continue automatically.

- **Retry now** requests another check without creating another mirroring session.
  It reloads saved settings and cancels the previous check.
- **Settings** opens the device wizard to change your connection settings.
- **Cancel** stops waiting. When the setup wizard is open, use its Cancel button.
- **Open logs** opens the diagnostics folder for troubleshooting.

Clicking the launcher again brings the existing connection, setup, or mirroring
window forward instead of opening another session. The connection window remains
visible until the phone's mirroring window opens. If that window cannot open,
check the error log and click **Retry now** or **Settings**.

Connection status reports the current check, including USB authorization and
Wi-Fi discovery. If the native process starts but its window does not appear
within 30 seconds, the app stops that attempt and offers a retry. This timeout
does not limit how long the app can wait for your phone to become available.

## Choose a connection

| Mode | What you need | How it works |
| --- | --- | --- |
| **USB** | A data cable and USB debugging | Mirrors over the cable; Wi-Fi setup is skipped. |
| **Wi-Fi** | Android 11+ and Wireless debugging | Pairs and mirrors without a USB cable. |
| **USB + Wi-Fi** (recommended) | Both of the above | Prefers USB at startup and reconnects over Wi-Fi if the cable is removed. |

### USB

1. Enable **Developer options** and **USB debugging** on your phone.
2. Connect a data-capable USB cable, unlock the phone, and accept the USB debugging
   authorization prompt. Allow this computer permanently if you trust it.
3. Choose **USB only** in the wizard, select your phone, and finish setup.

The location of Developer options varies by phone manufacturer. If your phone
is missing from the list, check the cable, accept the authorization prompt, and
click **Refresh**. Some phones require a manufacturer USB driver on Windows.

### Wi-Fi

1. Connect the phone and PC to the same network.
2. On the phone, enable **Developer options > Wireless debugging**, then open
   **Pair device with pairing code**. Keep this dialog open.
3. Choose **Wi-Fi only (no USB cable)** in the wizard, enter the six-digit code,
   and complete pairing.

The wizard tries to discover the phone's address automatically. If discovery fails, use
**Enter addresses manually**; see [Wi-Fi troubleshooting](#wi-fi-troubleshooting).
No USB cable or USB debugging authorization is needed for this mode.

For **USB + Wi-Fi**, complete both the USB selection and Wi-Fi pairing in the
wizard. Settings are saved for later launches.

## What happens when the cable is removed?

In **USB + Wi-Fi** mode, the mirroring window stays open, keeps the last frame
visible, and shows `Reconnecting...` while waiting for the phone. Video, audio,
and control resume after reconnection. Wi-Fi must remain available on both devices.

Switching back from Wi-Fi to USB requires restarting the app. Closing the window
stops reconnection attempts. You cannot control the phone while disconnected,
and the window may briefly stop responding while the old session shuts down.

## Requirements

- Windows x64 with Windows PowerShell 5.1 and Windows Script Host enabled.
- An Android device supported by [scrcpy 4.0](https://github.com/Genymobile/scrcpy/tree/v4.0#prerequisites).
- Android 11 or later for the Wi-Fi setup described above.
- A data-capable cable for USB; a shared network for Wi-Fi.

ADB and the required runtime libraries are included in the portable ZIP. Build
tools are not needed.

## Wi-Fi troubleshooting

**Pairing cannot find the phone:** choose **Enter addresses manually** and copy
**Pairing IP:port** from the phone's pairing-code dialog. Enter a fresh code if
that dialog was closed or the previous code expired.

**Pairing succeeds, but connection fails:** enter **Connection IP:port** from the
main **Wireless debugging** screen. This is a different port from the pairing
port. Both addresses must belong to the same phone. For example, an address looks
like `192.168.1.10:37000`; use the actual values shown on your phone.

If pairing has already succeeded in the current setup session, retry the
connection without entering another pairing code. Cancelling stops the current
check and keeps the previous saved settings. Pairing already completed on the
phone is not undone by cancellation.

**A saved connection stops working:** ensure Wireless debugging is still enabled
and both devices are on the same network. A manually entered connection address
can change after a network change or restart of Wireless debugging. Run
`Settings.vbs` again to update it. Pair again if the phone has forgotten the PC.

For other launch errors, check `last-run.log` and `last-run-errors.log` in the
`app/` folder (beside the launcher scripts in older flat installations). Setup errors appear in the wizard. Your device settings are
stored locally in `app/phone.json` (beside the launcher scripts in older flat installations); pairing codes are not saved. Release archives do
not contain personal device settings or logs.

## Limitations

Reconnection mode is intended for regular screen mirroring. Recording, session
time limits, and OTG/AOA are not supported in this mode. The portable build uses
ADB for USB mirroring and control; OTG is disabled at build time.

## Development

Start with [CONTRIBUTING.md](https://github.com/Nexusov/scrcpy/blob/main/CONTRIBUTING.md)
for the test command and contribution workflow. See the
[architecture](docs/ARCHITECTURE.md), [build and packaging guide](docs/BUILD.md), and
[native implementation notes](docs/CHANGES.md). The repository contains
source code and launch scripts; ready-to-run binaries are distributed through
[Releases](https://github.com/Nexusov/scrcpy/releases).

## License

scrcpy is licensed under [Apache-2.0](LICENSE). See [THIRD_PARTY.md](THIRD_PARTY.md)
for component provenance and dependency licensing information. Upstream copyright
notices and licensing are preserved.

This software uses FFmpeg libraries under LGPL-2.1-or-later. Corresponding
[dependency sources](https://github.com/Nexusov/scrcpy/releases/latest) are provided
alongside the portable download. Third-party license notices are included in
`app/licenses/` in the portable package (`licenses/` in the source repository).

