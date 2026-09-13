# PlaybackCore third-party build inputs

This file records the inputs and intended flags for `scripts/build-libmpv-ios.sh`.
The script downloads only the pinned source archives below, verifies SHA-256 before
extracting them, disables Meson wrap downloads, and writes all outputs outside the
repository by default.

## Source inputs

| Component | Version/tag | Source URL | SHA-256 |
| --- | --- | --- | --- |
| mpv | v0.40.0 (`e48ac7ce08462f5e33af6ef9deeac6fa87eef01e`) | <https://github.com/mpv-player/mpv> | `10a0f4654f62140a6dd4d380dcf0bbdbdcf6e697556863dc499c296182f081a3` |
| FFmpeg | n7.1.3 (`0a9a757e96fdf053697084bbd1f620edeac9d084`) | <https://github.com/FFmpeg/FFmpeg> | `e0b04c4b43d7e6d67cb6710334fb513adf13ac860532f30e1d0ac4c231f232fb` |
| libplacebo | v7.349.0 (`9c4b6bbd7a1e223ffdd61affc4e5d463d42d4345`) | <https://code.videolan.org/videolan/libplacebo> | `79120e685a1836344b51b13b6a5661622486a84e4d4a35f6c8d01679a20fbc86` |
| libass | 0.17.5 (`64ebcac709d949e6059bdacf5356c3af7848e8e5`) | <https://github.com/libass/libass> | `fa286fc9ee1ba3b932703a3df7b8474d01dc8abe29ec69b6fa68781dc4bf7acc` |
| FreeType | VER-2-13-3 (`534ad3456055ee1f65ecde3bcf22a656a31514d1`) | <https://github.com/freetype/freetype> | `bc5c898e4756d373e0d991bab053036c5eb2aa7c0d5c67e8662ddc6da40c4103` |
| HarfBuzz | 10.4.0 (`b39fe1a920f628201b6dad5e4266a5124dc92ef8`) | <https://github.com/harfbuzz/harfbuzz> | `0d25a3f74af4e8744700ac19050af5a80ae330378a5802a5cd71e523bb6fda1f` |
| FriBidi | v1.0.16 (`9123b467f080c7ea15509bd7cbd457817544a7e1`) | <https://github.com/fribidi/fribidi> | `5a1d187a33daa58fcee2ad77f0eb9d136dd6fa4096239199ba31e850d397e8a8` |
| fast_float (libplacebo submodule) | commit `2b2395f9ac836ffca6404424bcc252bff7aa80e4` | <https://github.com/fastfloat/fast_float> | `230d20e4e4ac1f6a9df92c4d746c6ec536cdb0c085bc8635d4b88cead5dc22cb` |
| Vulkan-Headers (libplacebo submodule) | commit `d732b2de303ce505169011d438178191136bfb00` | <https://github.com/KhronosGroup/Vulkan-Headers> | `570f9ae1e65466dbaf5fcab667abd079dd0a61c4ab86cf535efd492bf70a5b74` |

The source archives are the tagged upstream GitHub/VideoLAN archives. No source
patch is currently applied. The mpv v0.40.0 release is LGPL when configured with
`-Dgpl=false`; FFmpeg is configured with `--disable-gpl --disable-nonfree`.
Final distribution still requires a project-level license review of the exact
linkage and all transitive components.

## Build-time Python inputs

The libplacebo shader generator runs in a build-local virtual environment under
the temporary build root. `scripts/libmpv-build-requirements.txt` pins and
hash-locks Jinja2 3.1.6 and MarkupSafe 3.0.3; the script does not modify the
system or Codex Python installation.

## Build configuration

- Outputs: arm64 iOS and arm64 iOS Simulator, deployment target iOS 17.0.
- mpv: static libmpv, `-Dgpl=false`, `-Dcplayer=false`, `-Dlibmpv=true`, `-Dgl=enabled`, `-Dplain-gl=enabled`, experimental official `-Dios-gl=enabled` interop, `-Dvideotoolbox-gl=disabled`, `-Dvideotoolbox-pl=disabled`, `-Dvulkan=disabled`, `-Dlua=disabled`, `-Djavascript=disabled`, `-Duchardet=disabled`. Release builds use the validated `videotoolbox-copy` hardware-decoding backend.
- FFmpeg: static, PIC, cross-compiled for Darwin, programs/docs and avdevice disabled, `--disable-gpl`, `--disable-nonfree`, `--disable-autodetect`, VideoToolbox enabled. AudioUnit is provided by mpv; FFmpeg AudioToolbox codec support is not enabled.
- libplacebo: static, Vulkan/OpenGL/shaderc/demos/tests disabled for the initial `vo=libmpv` path.
- libass: static, CoreText enabled, Fontconfig/DirectWrite/assembly/tests disabled.
- HarfBuzz, FreeType and FriBidi: static, tests/docs/utilities and unrelated platform backends disabled.
- Meson is invoked with `--wrap-mode nodownload`; no dependency is silently fetched.

The output combines the static dependency archives into one `libmpv.a` per
platform before `xcodebuild -create-xcframework`. The locally generated
XCFramework is copied to `Frameworks/MPV/libmpv.xcframework` and ignored by
Git; rebuild it with `MIVU_LIBMPV_INSTALL_DIR="$PWD/Frameworks/MPV"
scripts/build-libmpv-ios.sh`. Frameworks required by the app link (including
VideoToolbox, CoreVideo, CoreText, OpenGLES, AudioToolbox, zlib, iconv and
`libc++` are declared in the project but still require device link/runtime
review. `libc++` is required by static libplacebo C++ objects (for example
`std::__1` symbols). The simulator slice is arm64-only; Intel x86_64
simulators are intentionally unsupported and excluded from the app target.

## Current verification status

The full two-platform archive build completed locally (69 MB; arm64 device and
arm64 simulator). The app selects MPV only for explicit non-Native container
hints (`mkv`, `webm`, `avi`, `flv`, `ts`, `m2ts`, `ogv`) and keeps generic server
`/stream` URLs on AVPlayer. mpv's official `ios-gl` hardware interop is enabled
as an experimental path; the legacy `videotoolbox-gl`/`videotoolbox-pl` paths
remain disabled. Release builds use the validated `videotoolbox-copy`
backend, and the OpenGL ES Render API surface remains enabled.
A successful archive build does not establish decoder coverage, render
correctness, AirPlay/PiP/CarPlay compatibility, or App Store license
compliance; those remain device and distribution acceptance work.
