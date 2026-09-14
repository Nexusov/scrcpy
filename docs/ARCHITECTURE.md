# Launcher architecture

The native client owns mirroring and in-window reconnection. PowerShell owns
onboarding, device selection, startup progress, and native process lifetime.
The public VBS files start PowerShell without a console. They support the current
`app/` package layout and older flat installations.

## Boundaries

`launch.ps1` and `setup.ps1` compose their dependencies and views, enter the Windows
Forms event loop, and dispose their resources. Importing a session or view module
does not display a window or start a device operation.

- **Sessions** accept plain input and explicit dependencies. They decide whether
  to discover, pair, save, reset, retry, or stop. They never inspect form controls.
- **Views** create controls, convert edits to input snapshots, call session
  actions, and render presentation data. Confirmation dialogs belong here.
- **Runtime adapters** create runspaces and child processes. Each operation owns
  its cancellation source and process resources.
- **Shared services** contain the ADB process boundary, configuration store,
  device discovery, pairing, shortcut creation, and instance coordination.

`New-LaunchDependencies` and `New-SetupDependencies` bind real effects. Tests replace
these effects when exercising controllers; adapter tests use disposable real
processes. A session can therefore be tested without creating a form.

## Connection lifecycle

`launch-session.ps1` uses `Phase` as the lifecycle authority:

| Phase | Meaning |
| --- | --- |
| `Waiting` | A new discovery attempt may be scheduled. |
| `Probing` | One device discovery worker is active. |
| `Starting` | The native process exists; its window has not appeared. |
| `Streaming` | The native window is visible and owns mirroring. |
| `Settings` | The Settings child owns the configuration interaction. |
| `Failed` | Automatic attempts are paused until an explicit user action. |
| `Closing` | No new work may start; owned resources are released. |

Each probe captures a detached configuration snapshot and a generation number.
Retry invalidates the previous generation before reading settings again. Results
and progress from an older attempt cannot authorize a new native launch.

Before native startup, the controller rereads saved configuration under the same
lock used by save and reset. A changed phone, mode, or address invalidates the probe.
A reset pauses the launcher until the user saves settings and retries. This final
validation and process creation stay within one lock scope.

Only native startup has a deadline. Device discovery may keep retrying while the
phone is unavailable. Closing an established mirroring window ends the launcher;
it does not start another stream. A repeated public launch signals the existing
instance, which focuses its waiting, Settings, or native window.

## Settings and persistence

`setup-session.ps1` owns editable `Input`, `SavedConfiguration`, `PairingState`,
one `PendingWork`, and an `Outcome` of `Open`, `Saved`, or `Cancelled`. Action
availability is derived from these values; it is not stored in button flags.

Saving and reset go through `configuration-store.ps1`. Saves validate configuration
fields and mode, compare the expected file snapshot, and replace the file
atomically. An absent file and an empty file are distinct snapshots. Another
Settings window must not silently overwrite a save or restore a reset configuration.

Cancellation discards pending results before persistence. Pairing already completed
on the phone remains available for a connection retry within the current session.
Pairing codes are never persisted and are redacted from operation errors.
Shortcut failure is reported separately after a successful configuration save.

Reset deletes only this runtime's `phone.json` after confirmation and refuses an
active native session from the same runtime. It keeps shared ADB trust, phone-side
pairing, logs, and desktop shortcuts.

## Sources of truth

| Concern | Owner |
| --- | --- |
| Mode inference, configuration validation, locking, save/reset | `configuration-store.ps1` |
| ADB arguments, timeout, cancellation, and child cleanup | `adb-process.ps1` |
| Connection selection and status hints | `connection-core.ps1` |
| Discovery and pairing protocol | `launcher-core.ps1` |
| Release labels and reviewed native/runtime hashes | `release-manifest.json` |
| Native build identity and package selection | `scripts/provenance.ps1` |
| Files admitted to the portable archive | `scripts/package.ps1` |

## Verification boundaries

The `scripts/test.ps1` runner covers controller transitions, retained
pairing, configuration conflicts, exact reset scope, view events, process-local
environment, timeouts, instance exclusion, VBS wrappers, package selection, and
local publication behavior. Test processes run in an owned Windows Job Object;
the startup handshake prevents a suite from spawning children before assignment.

Automated tests do not prove physical USB-to-Wi-Fi reconnection, audio recovery, or
behavior on every manufacturer's Android build. Before a release, use a real phone
to check USB, Wi-Fi, repeated launch, Retry after a settings change, cancellation,
and unplugging USB during combined-mode mirroring. Confirm the same window resumes
video, audio, and control. Use disposable settings for reset tests.

Native ownership and the fork-specific files are documented in [CHANGES.md](CHANGES.md).
Build and release checks are documented in [BUILD.md](BUILD.md) and
[PACKAGING.md](PACKAGING.md).
