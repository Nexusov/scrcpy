# Contributing

Start with a focused issue or pull request describing the behavior you want to
change. Keep unrelated cleanup separate so reviewers can assess each change.

## Run the checks

Use Windows with Windows PowerShell 5.1 and Git. From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\test.ps1
```

The runner discovers `tests/*.Tests.ps1`, parses the PowerShell sources, and runs
each suite in its own PowerShell 5.1 STA process. It retains logs and a JSON summary
under `dist/test-results/` and returns a nonzero exit code if any suite fails.
Timed-out suites and their child processes are stopped together.

Tests use synthetic devices, temporary files, private shortcut directories, and
isolated instance locks. They require no phone, downloaded runtime, or GitHub
credentials. Publication tests push only to disposable local repositories.
GitHub Actions runs the same command on Windows for pull requests and `main`.

## Find the right module

| Area | Location |
| --- | --- |
| Public launchers and compatibility wrappers | `launcher/*.vbs` |
| Startup and settings application entry points | `launcher/launch.ps1`, `launcher/setup.ps1` |
| State transitions and user actions | `launcher/*-session.ps1` |
| Windows Forms controls and event bindings | `launcher/*-view.ps1` |
| Background workers and native process adapters | `launcher/*-runtime.ps1` |
| ADB execution and configuration persistence | `launcher/adb-process.ps1`, `launcher/configuration-store.ps1` |
| Device discovery and pairing | `launcher/connection-core.ps1`, `launcher/launcher-core.ps1` |
| Native scrcpy fork | `src/scrcpy/` |
| Build, packaging, and publication | `scripts/` |

See [architecture and invariants](docs/ARCHITECTURE.md) before changing connection
recovery, cancellation, reset, or process ownership. For native development and
portable ZIP creation, follow [BUILD.md](docs/BUILD.md).

## Prepare a pull request

- Describe the problem, resulting behavior, and checks you ran.
- Test behavior through imported functions and explicit dependencies. Do not
  extract functions from source text or rewrite application code inside tests.
- Keep control access in views, connection policies in sessions, and effects in
  adapters. Comment ownership and non-obvious constraints instead of restating code.
- Preserve USB, Wi-Fi, combined mode, saved settings, and old launcher compatibility.
- Never commit `phone.json`, pairing codes, ADB keys, logs, shortcuts, local build
  configuration, downloaded dependencies, or generated ZIPs.
- Add new runtime modules to the packager's explicit file list and validate a ZIP
  if you change imports, wrappers, documentation paths, or package layout.

## Update upstream or publish

Keep an upstream update separate from launcher refactoring. Compare the native
changes listed in [CHANGES.md](docs/CHANGES.md) against the selected upstream tag;
preserve notices, review reconnection cleanup, then rebuild and test real USB
disconnection. Do not change the imported baseline hashes just to bypass a failed
packaging check. Dependency changes also require updated notices and source archives.

Maintainers should follow [PACKAGING.md](docs/PACKAGING.md) for provenance and the
publication workflow. The publisher pushes `main` and then moves the existing
release tag with a lease; uploading the portable ZIP and matching checksum remains
a separate step. Test changes and the exact package before publishing.
