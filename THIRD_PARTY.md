# Third-party components

scrcpy Seamless is based on Genymobile scrcpy 4.0. The original copyright
notices and [Apache-2.0 license](LICENSE) are retained. Local modifications are
described in [docs/CHANGES.md](docs/CHANGES.md).

## Portable package

| Component | Version | License / notices |
| --- | --- | --- |
| scrcpy client and Android server | 4.0 with client reconnection changes | Apache-2.0, `LICENSE` |
| SDL | 3.4.8 | zlib license, `licenses/SDL-LICENSE.txt` |
| FFmpeg libraries | 8.1.1 | LGPL-2.1-or-later, `licenses/FFmpeg-LGPL-2.1.txt` and `licenses/FFmpeg-LICENSE.md` |
| dav1d, embedded in FFmpeg | 1.5.3 | BSD-2-Clause, `licenses/dav1d-COPYING.txt` |
| zlib, embedded in FFmpeg | 1.3.1 | zlib license, `licenses/zlib-LICENSE.txt` |
| Android Debug Bridge and Windows ADB libraries | 34.0.5-10900879 | Full upstream notices in `licenses/Android-Platform-Tools-NOTICE.txt` |
| GCC / MinGW runtime support | Compiler runtime components | Notices and GCC Runtime Library Exception in `licenses/` |

The third-party components retain their own licenses. They are not relicensed
under the scrcpy Apache-2.0 license. The GCC GPL text accompanies its runtime
exception; it does not change the stated scrcpy or FFmpeg license.

## Binary provenance

The SDL and FFmpeg DLLs and Android server were verified byte-for-byte against
[the official scrcpy 4.0 Windows x64 package](https://github.com/Genymobile/scrcpy/releases/tag/v4.0).
The three ADB binaries were verified against Google's
[Platform Tools 34.0.5 Windows package](https://dl.google.com/android/repository/platform-tools_r34.0.5-windows.zip).
The scrcpy client is locally rebuilt with the changes in this repository.

The FFmpeg DLLs report version 8.1.1 and LGPL-2.1-or-later at runtime. Their
configuration uses shared libraries and does not enable GPL or nonfree features.
SDL, FFmpeg, and dav1d source archive hashes match the versions pinned by the
upstream scrcpy dependency scripts. Embedded zlib version strings identify 1.3.1.

## Corresponding sources

This software uses libraries from the FFmpeg project under LGPL-2.1-or-later.
Download `scrcpy-seamless-dependency-sources.zip` from the
[same release as the portable package](https://github.com/Nexusov/scrcpy/releases/latest).
It contains unmodified FFmpeg 8.1.1, dav1d 1.5.3, zlib 1.3.1, and SDL 3.4.8
source archives, source checksums, upstream dependency build scripts, and the
configuration reported by the shipped FFmpeg DLL. No local changes were made
to those dependency sources or binaries.

The application dynamically links to the FFmpeg DLLs. Compatible modified DLLs
can replace them in the application directory. This project adds no restriction
on reverse engineering for debugging modifications to LGPL-covered libraries.

Publish the source companion alongside every portable release. The repository
does not include compiler installations or SDKs. Exact upstream compiler package
revisions have not been reconstructed, and bit-identical rebuilding is not claimed.
