# Building for Windows x64

The portable application does not require a compiler. This guide covers development
and rebuilding the modified client.

## Dependencies

Install a C11-capable GCC toolchain, binutils (`ar`, `windres`), pkg-config, Meson,
Ninja, and the SDL3 and FFmpeg development headers and libraries. The validated
build used GCC from w64devkit 2.9.1, Meson 1.12.0, Ninja 1.13.2, SDL 3.4.8, and
FFmpeg 8.1. Build tools are installed separately and are not tracked in Git.

An MSYS2 MinGW64 environment can also provide the required tools through
`mingw-w64-x86_64-gcc`, `mingw-w64-x86_64-pkg-config`,
`mingw-w64-x86_64-meson`, `mingw-w64-x86_64-ninja`,
`mingw-w64-x86_64-sdl3`, and `mingw-w64-x86_64-ffmpeg`.
Use matching headers, import libraries, and runtime DLLs for the same architecture.
See the [upstream build instructions](https://github.com/Genymobile/scrcpy/blob/v4.0/doc/build.md).

## Build the client

If the tools are available on `PATH`, run this command from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1
```

For tools installed in separate locations, copy `scripts/build.example.json` to
`scripts/build.local.json`. Set absolute paths to the executables and the SDL3 and
FFmpeg `lib/pkgconfig` directories, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1 -ConfigPath .\scripts\build.local.json
```

`compilerBinDirectory` is optional. For w64devkit, it supplies the `-B` prefix that
allows GCC to locate the assembler and linker. The local configuration is excluded
from Git.

The resulting executable is written to `dist/scrcpy.exe`; intermediate files are
stored in `.build/`. The application in `outputs/` is not replaced automatically.
Start with an empty `.build/` directory when changing compilers.

The script automates the build commands but does not guarantee byte-identical
output across different compiler and dependency versions.

## Create a portable package

The client executable also needs compatible runtime DLLs, ADB, and the
**scrcpy v4.0** Android server. Use a separate, validated runtime directory.
Download the [v4.0 Android server](https://github.com/Genymobile/scrcpy/releases/download/v4.0/scrcpy-server-v4.0).

Server SHA-256:
`84924bd564a1eb6089c872c7521f968058977f91f5ff02514a8c74aff3210f3a`.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\package.ps1 -RuntimeDirectory "C:\path\to\tested-runtime"
```

Without this parameter, the script uses `outputs/scrcpy-seamless`.
It produces `dist/scrcpy-seamless-win64.zip` and a SHA-256 checksum file.

The archive includes `phone.example.json` and excludes personal `phone.json`
settings, logs, and build tools. Before distributing a package publicly, include
the license notices and source information for the specific dependency binaries
in that package.

After validating the build, you can remove `.build/` and downloaded build tools.
