# Components and provenance

This repository contains scrcpy source code derived from Genymobile/scrcpy
v4.0, commit `2322868e9e256eb5fce0b3d659ab2a409f29bae1`.
Upstream copyright notices and the Apache-2.0 license are retained.
The reconnect modifications are documented in `docs/CHANGES.md`.

Compiled dependencies are not tracked in this source repository. A portable
package also uses the following independently maintained components:

- SDL 3.4.8: https://github.com/libsdl-org/SDL/tree/release-3.4.8
- FFmpeg 8.1 libraries: https://ffmpeg.org/
- Android Debug Bridge, Platform Tools 34.0.5: https://developer.android.com/tools/releases/platform-tools
- scrcpy Android server v4.0: https://github.com/Genymobile/scrcpy/releases/tag/v4.0

The existing local portable build reuses its existing runtime DLLs and ADB
binaries. These dependencies are covered by their respective licenses, not
by a blanket relicensing under this repository's Apache-2.0 license.
When distributing new dependency binaries, include their corresponding license
and source information. This repository does not vendor a compiler or SDK.
