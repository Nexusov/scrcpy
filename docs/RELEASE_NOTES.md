scrcpy Seamless is a portable Windows fork of [scrcpy 4.0](https://github.com/Genymobile/scrcpy/releases/tag/v4.0) with guided device setup, convenient graphical settings, and automatic USB-to-Wi-Fi reconnection.

## Features

- Connect over USB, Wi-Fi, or USB + Wi-Fi.
- Configure your phone through a guided setup wizard without terminal commands or manual JSON editing.
- Set up Wi-Fi without a USB cable.
- Adjust picture quality, maximum resolution, FPS limit, bit rate, and sound in Settings.
- Browse the full scrcpy option catalogue in Advanced, with search, groups, and explanations. Only the selected parameter's editor is displayed, keeping the interface responsive.
- Save preferences between launches and restore mirroring defaults separately from device setup.
- View available encoders, cameras, and other device information without using a terminal.
- In USB + Wi-Fi mode, prioritize USB at startup and automatically reconnect over Wi-Fi when the cable is removed.
- Keep the same mirroring window and last frame visible during reconnection, then resume video, audio, and control.
- Repeated launches bring the existing setup, connection, or mirroring window forward instead of starting another stream.
- Optionally create or update a desktop shortcut from Settings.
- Run without a separate console window.

## Downloads

- **`scrcpy-seamless-win64.zip`** — portable Windows x64 application. Download this to use scrcpy Seamless.
- **`scrcpy-seamless-dependency-sources.zip`** — dependency source archives and build information; not required to run the application.
- **`.sha256` files** — checksums for verifying the downloads.

## Quick start

1. Download and extract `scrcpy-seamless-win64.zip` into an empty, writable folder. Do not extract it over an older version.
2. Double-click `Start.vbs`.
3. Choose USB, Wi-Fi, or USB + Wi-Fi and follow the setup wizard.

### USB

Enable USB debugging on your phone, connect it with a data-capable cable, and authorize your PC.

### Wi-Fi

Connect the phone and PC to the same network and enable **Wireless debugging** on the phone.

Open **Developer options > Wireless debugging > Pair device with pairing code**, then enter the six-digit code in the setup wizard.

### USB + Wi-Fi — recommended

Complete both USB authorization and Wi-Fi pairing. With Seamless reconnection enabled, the app uses USB when available at startup and reconnects over Wi-Fi if the cable is removed.

Device settings are saved when you finish setup. For subsequent launches, use `Start.vbs` or your desktop shortcut.

## Convenient settings

Open **`Settings.vbs`** to configure the application:

- **Connection** — change the phone or connection mode, reset device setup, or create/update a desktop shortcut.
- **Mirroring** — adjust maximum resolution, video bit rate, FPS limit, audio, and Seamless reconnection.
- **Advanced** — search or browse additional video, audio, camera, recording, window, input, and diagnostic options. Select a parameter to edit it; switching parameters or filtering the list preserves your unsaved values.

Click **Save mirroring settings**, then restart mirroring to apply changes. Blank fields use scrcpy defaults. A higher FPS limit does not increase the frame rate of the original video or guarantee that the device can sustain it.

**Restore mirroring defaults** resets mirroring preferences without removing the saved phone. **Reset device setup** removes this application's phone configuration while keeping mirroring preferences, shortcuts, logs, and shared ADB keys.

Settings explains common conflicts before saving. Options managed by the connection wizard or unavailable in this build remain visible with an explanation. Device-specific capabilities are checked by scrcpy when launched.

For detailed setup instructions, connection recovery, troubleshooting, logs, and package layout, see the [repository README](https://github.com/Nexusov/scrcpy#readme).

## Requirements

- Windows x64 with Windows PowerShell 5.1 and Windows Script Host.
- An Android device compatible with scrcpy 4.0.
- For USB: USB debugging authorization, a data-capable cable, and a device driver if required.
- For Wi-Fi: Android 11 or later, Wireless debugging, and the phone and PC on the same network.

ADB and the required runtime libraries are included. No installation, compiler, or development tools are required.

## Known limitations

- Automatic switching works from USB to Wi-Fi in USB + Wi-Fi mode with Seamless reconnection enabled.
- Switching back from Wi-Fi to USB requires restarting the app.
- Device control is unavailable while reconnecting. The mirroring window may briefly stop responding while the previous session shuts down.
- Recording, session time limits, and modes without video playback require disabling Seamless reconnection.
- OTG/AOA is unavailable in this portable build. V4L2 output requires Linux. Camera and codec support depend on the phone.
- Closing the mirroring window stops the app, including reconnection attempts. Headless sessions keep the launcher visible so you can stop them.
- Stopping a session requests normal shutdown so recordings can finish writing. If the native process hangs for more than ten seconds, it is forcibly stopped and an active recording may be incomplete.

## Licenses and dependency sources

Based on [Genymobile scrcpy 4.0](https://github.com/Genymobile/scrcpy/releases/tag/v4.0), licensed under Apache-2.0. scrcpy Seamless is an independent project and is not an official Genymobile release.

Third-party license notices are included in [`licenses/`](https://github.com/Nexusov/scrcpy/tree/main/licenses), with component information in [`THIRD_PARTY.md`](https://github.com/Nexusov/scrcpy/blob/main/THIRD_PARTY.md).

This software uses FFmpeg 8.1.1 libraries under LGPL-2.1-or-later. The attached `scrcpy-seamless-dependency-sources.zip` contains the corresponding FFmpeg, dav1d, zlib, and SDL source archives, checksums, and build information.

Personal device settings, mirroring preferences, and logs are not included in distributed archives.
