#!/usr/bin/env bash
set -euo pipefail

# Reproducible, source-only libmpv build for Mivu. The script intentionally
# keeps all downloads and build products outside the repository by default.
# It does not use prebuilt binaries or Meson wrap downloads.

readonly MPV_VERSION="v0.40.0"
readonly MPV_COMMIT="e48ac7ce08462f5e33af6ef9deeac6fa87eef01e"
readonly FFMPEG_VERSION="n7.1.3"
readonly LIBPLACEBO_VERSION="v7.349.0"
readonly LIBASS_VERSION="0.17.5"
readonly FREETYPE_VERSION="VER-2-13-3"
readonly HARFBUZZ_VERSION="10.4.0"
readonly FRIBIDI_VERSION="v1.0.16"
readonly FAST_FLOAT_COMMIT="2b2395f9ac836ffca6404424bcc252bff7aa80e4"
readonly VULKAN_HEADERS_COMMIT="d732b2de303ce505169011d438178191136bfb00"
readonly IOS_MIN_VERSION="17.0"

readonly MPV_SHA256="10a0f4654f62140a6dd4d380dcf0bbdbdcf6e697556863dc499c296182f081a3"
readonly FFMPEG_SHA256="e0b04c4b43d7e6d67cb6710334fb513adf13ac860532f30e1d0ac4c231f232fb"
readonly LIBPLACEBO_SHA256="79120e685a1836344b51b13b6a5661622486a84e4d4a35f6c8d01679a20fbc86"
readonly LIBASS_SHA256="fa286fc9ee1ba3b932703a3df7b8474d01dc8abe29ec69b6fa68781dc4bf7acc"
readonly FREETYPE_SHA256="bc5c898e4756d373e0d991bab053036c5eb2aa7c0d5c67e8662ddc6da40c4103"
readonly HARFBUZZ_SHA256="0d25a3f74af4e8744700ac19050af5a80ae330378a5802a5cd71e523bb6fda1f"
readonly FRIBIDI_SHA256="5a1d187a33daa58fcee2ad77f0eb9d136dd6fa4096239199ba31e850d397e8a8"
readonly FAST_FLOAT_SHA256="230d20e4e4ac1f6a9df92c4d746c6ec536cdb0c085bc8635d4b88cead5dc22cb"
readonly VULKAN_HEADERS_SHA256="570f9ae1e65466dbaf5fcab667abd079dd0a61c4ab86cf535efd492bf70a5b74"

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly WORK_ROOT="${MIVU_LIBMPV_BUILD_ROOT:-${TMPDIR:-/tmp}/mivu-libmpv-build}"
readonly SOURCE_ROOT="$WORK_ROOT/sources"
readonly BUILD_ROOT="$WORK_ROOT/build"
readonly OUTPUT_ROOT="$WORK_ROOT/output"
readonly VENV_ROOT="$WORK_ROOT/venv"
readonly INSTALL_ROOT="${MIVU_LIBMPV_INSTALL_DIR:-}"
readonly JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

readonly MPV_URL="https://github.com/mpv-player/mpv/archive/refs/tags/${MPV_VERSION}.tar.gz"
readonly FFMPEG_URL="https://github.com/FFmpeg/FFmpeg/archive/refs/tags/${FFMPEG_VERSION}.tar.gz"
readonly LIBPLACEBO_URL="https://code.videolan.org/videolan/libplacebo/-/archive/${LIBPLACEBO_VERSION}/libplacebo-${LIBPLACEBO_VERSION}.tar.gz"
readonly LIBASS_URL="https://github.com/libass/libass/archive/refs/tags/${LIBASS_VERSION}.tar.gz"
readonly FREETYPE_URL="https://github.com/freetype/freetype/archive/refs/tags/${FREETYPE_VERSION}.tar.gz"
readonly HARFBUZZ_URL="https://github.com/harfbuzz/harfbuzz/archive/refs/tags/${HARFBUZZ_VERSION}.tar.gz"
readonly FRIBIDI_URL="https://github.com/fribidi/fribidi/archive/refs/tags/${FRIBIDI_VERSION}.tar.gz"
readonly FAST_FLOAT_URL="https://github.com/fastfloat/fast_float/archive/${FAST_FLOAT_COMMIT}.tar.gz"
readonly VULKAN_HEADERS_URL="https://github.com/KhronosGroup/Vulkan-Headers/archive/${VULKAN_HEADERS_COMMIT}.tar.gz"

export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PKG_CONFIG="${PKG_CONFIG:-$(command -v pkg-config)}"
readonly MESON="$(command -v meson)"

die() { echo "error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null || die "missing command: $1"; }

for command in curl shasum tar meson ninja xcodebuild xcrun clang libtool; do
    require_command "$command"
done

mkdir -p "$SOURCE_ROOT" "$BUILD_ROOT" "$OUTPUT_ROOT"

# Keep Python build helpers isolated from the host/Codex runtime. Meson will
# discover this interpreter for libplacebo's shader generation commands.
if [[ ! -x "$VENV_ROOT/bin/python3" || -L "$VENV_ROOT/bin/python3" ]]; then
    rm -rf "$VENV_ROOT"
    python3 -m venv --copies "$VENV_ROOT"
fi
"$VENV_ROOT/bin/python3" -m pip install \
    --disable-pip-version-check --require-hashes --no-deps \
    --requirement "$ROOT_DIR/scripts/libmpv-build-requirements.txt" >/dev/null
export PATH="$VENV_ROOT/bin:$PATH"

fetch_archive() {
    local name="$1" url="$2" expected="$3"
    local archive="$SOURCE_ROOT/$name.tar.gz"
    if [[ ! -f "$archive" ]]; then
        curl --fail --location --silent --show-error "$url" --output "$archive"
    fi
    printf '%s  %s\n' "$expected" "$archive" | shasum -a 256 --check --strict
}

extract_archive() {
    local name="$1" directory="$2"
    if [[ ! -d "$SOURCE_ROOT/$directory" ]]; then
        tar -xzf "$SOURCE_ROOT/$name.tar.gz" -C "$SOURCE_ROOT"
    fi
    [[ -d "$SOURCE_ROOT/$directory" ]] || die "unexpected archive layout for $name"
}

fetch_archive "mpv-$MPV_VERSION" "$MPV_URL" "$MPV_SHA256"
fetch_archive "ffmpeg-$FFMPEG_VERSION" "$FFMPEG_URL" "$FFMPEG_SHA256"
fetch_archive "libplacebo-$LIBPLACEBO_VERSION" "$LIBPLACEBO_URL" "$LIBPLACEBO_SHA256"
fetch_archive "libass-$LIBASS_VERSION" "$LIBASS_URL" "$LIBASS_SHA256"
fetch_archive "freetype-$FREETYPE_VERSION" "$FREETYPE_URL" "$FREETYPE_SHA256"
fetch_archive "harfbuzz-$HARFBUZZ_VERSION" "$HARFBUZZ_URL" "$HARFBUZZ_SHA256"
fetch_archive "fribidi-$FRIBIDI_VERSION" "$FRIBIDI_URL" "$FRIBIDI_SHA256"
fetch_archive "fast_float-$FAST_FLOAT_COMMIT" "$FAST_FLOAT_URL" "$FAST_FLOAT_SHA256"
fetch_archive "Vulkan-Headers-$VULKAN_HEADERS_COMMIT" "$VULKAN_HEADERS_URL" "$VULKAN_HEADERS_SHA256"

extract_archive "mpv-$MPV_VERSION" "mpv-0.40.0"
extract_archive "ffmpeg-$FFMPEG_VERSION" "FFmpeg-$FFMPEG_VERSION"
extract_archive "libplacebo-$LIBPLACEBO_VERSION" "libplacebo-$LIBPLACEBO_VERSION"
extract_archive "libass-$LIBASS_VERSION" "libass-$LIBASS_VERSION"
extract_archive "freetype-$FREETYPE_VERSION" "freetype-$FREETYPE_VERSION"
extract_archive "harfbuzz-$HARFBUZZ_VERSION" "harfbuzz-$HARFBUZZ_VERSION"
extract_archive "fribidi-$FRIBIDI_VERSION" "fribidi-1.0.16"
extract_archive "fast_float-$FAST_FLOAT_COMMIT" "fast_float-$FAST_FLOAT_COMMIT"
extract_archive "Vulkan-Headers-$VULKAN_HEADERS_COMMIT" "Vulkan-Headers-$VULKAN_HEADERS_COMMIT"

# libplacebo's release archive leaves this submodule empty. Populate it from
# the exact submodule commit recorded by the pinned libplacebo tag.
rm -rf "$SOURCE_ROOT/libplacebo-$LIBPLACEBO_VERSION/3rdparty/fast_float"
mkdir -p "$SOURCE_ROOT/libplacebo-$LIBPLACEBO_VERSION/3rdparty/fast_float"
cp -R "$SOURCE_ROOT/fast_float-$FAST_FLOAT_COMMIT/." \
    "$SOURCE_ROOT/libplacebo-$LIBPLACEBO_VERSION/3rdparty/fast_float/"
rm -rf "$SOURCE_ROOT/libplacebo-$LIBPLACEBO_VERSION/3rdparty/Vulkan-Headers"
mkdir -p "$SOURCE_ROOT/libplacebo-$LIBPLACEBO_VERSION/3rdparty/Vulkan-Headers"
cp -R "$SOURCE_ROOT/Vulkan-Headers-$VULKAN_HEADERS_COMMIT/." \
    "$SOURCE_ROOT/libplacebo-$LIBPLACEBO_VERSION/3rdparty/Vulkan-Headers/"

readonly IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
readonly SIMULATOR_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
readonly IOS_CLANG="$(xcrun --sdk iphoneos --find clang)"
readonly IOS_AR="$(xcrun --sdk iphoneos --find ar)"
readonly IOS_RANLIB="$(xcrun --sdk iphoneos --find ranlib)"
readonly IOS_STRIP="$(xcrun --sdk iphoneos --find strip)"
readonly SIM_CLANG="$(xcrun --sdk iphonesimulator --find clang)"
readonly SIM_AR="$(xcrun --sdk iphonesimulator --find ar)"
readonly SIM_RANLIB="$(xcrun --sdk iphonesimulator --find ranlib)"
readonly SIM_STRIP="$(xcrun --sdk iphonesimulator --find strip)"

write_cross_file() {
    local output="$1" sdk="$2" clang="$3" ar="$4" ranlib="$5" strip="$6" target="$7" min_flag="$8"
    cat > "$output" <<EOF
[binaries]
c = '$clang'
cpp = '$clang++'
objc = '$clang'
ar = '$ar'
ranlib = '$ranlib'
strip = '$strip'
pkgconfig = '$PKG_CONFIG'
python = '$VENV_ROOT/bin/python3'
python3 = '$VENV_ROOT/bin/python3'

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[built-in options]
default_library = 'static'
buildtype = 'release'
b_lto = false
c_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-target', '$target', '$min_flag', '-fno-common']
cpp_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-target', '$target', '$min_flag', '-fno-common']
objc_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-target', '$target', '$min_flag', '-fno-common']
c_link_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-target', '$target', '$min_flag']
cpp_link_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-target', '$target', '$min_flag']
objc_link_args = ['-arch', 'arm64', '-isysroot', '$sdk', '-target', '$target', '$min_flag']
EOF
}

build_meson() {
    local name="$1" source="$2" cross_file="$3"
    shift 3
    local build_dir="$BUILD_ROOT/$name-$(basename "$cross_file" .ini)"
    rm -rf "$build_dir"
    "$MESON" setup "$build_dir" "$source" --cross-file "$cross_file" --wrap-mode nodownload --prefix "$PREFIX" --libdir lib "$@"
    "$MESON" compile -C "$build_dir" -j "$JOBS"
    "$MESON" install -C "$build_dir"
}

build_ffmpeg() {
    local cross_file="$1"
    local source="$SOURCE_ROOT/FFmpeg-$FFMPEG_VERSION" build_dir="$BUILD_ROOT/ffmpeg-$(basename "$cross_file" .ini)"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    pushd "$source" >/dev/null
    make distclean >/dev/null 2>&1 || true
    ./configure \
        --prefix="$PREFIX" \
        --pkg-config="$PKG_CONFIG" --pkg-config-flags="--static" \
        --target-os=darwin --arch=arm64 --enable-cross-compile \
        --cc="$CLANG" --ar="$AR" --ranlib="$RANLIB" --strip="$STRIP" \
        --sysroot="$SDK" \
        --extra-cflags="$CFLAGS -I$PREFIX/include" \
        --extra-ldflags="$LDFLAGS -L$PREFIX/lib" \
        --disable-programs --disable-doc --disable-debug \
        --disable-shared --enable-static --enable-pic \
        --disable-gpl --disable-nonfree --disable-autodetect --disable-avdevice \
        --enable-network --enable-securetransport \
        --enable-protocol=file,http,https,tcp,tls \
        --enable-videotoolbox \
        --enable-decoder=vp8,vp9,opus,vorbis,flac,aac,h264,hevc,av1,mp3,pcm_s16le,pcm_s24le,ass,srt,subrip,webvtt \
        --enable-demuxer=matroska,mov,mpegts,hls,dash,mp3,ogg,flac,avi,concat,srt,ass,webvtt
    make -j "$JOBS"
    make install
    popd >/dev/null
}

build_target() {
    local target_name="$1" sdk="$2" clang="$3" ar="$4" ranlib="$5" strip="$6" target="$7" min_flag="$8"
    local cross_file="$WORK_ROOT/cross-$target_name.ini"
    write_cross_file "$cross_file" "$sdk" "$clang" "$ar" "$ranlib" "$strip" "$target" "$min_flag"
    PREFIX="$WORK_ROOT/prefix-$target_name"
    SDK="$sdk" CLANG="$clang" AR="$ar" RANLIB="$ranlib" STRIP="$strip"
    CFLAGS="-arch arm64 -isysroot $sdk -target $target $min_flag -fno-common"
    LDFLAGS="-arch arm64 -isysroot $sdk -target $target $min_flag"
    export PREFIX SDK CLANG AR RANLIB STRIP CFLAGS LDFLAGS
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
    export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

    build_meson "harfbuzz" "$SOURCE_ROOT/harfbuzz-$HARFBUZZ_VERSION" "$cross_file" \
        -Dglib=disabled -Dgobject=disabled -Dfreetype=disabled -Dicu=disabled \
        -Dgraphite=disabled -Dgraphite2=disabled -Dcairo=disabled -Dtests=disabled \
        -Dutilities=disabled -Ddocs=disabled -Dbenchmark=disabled
    build_meson "freetype" "$SOURCE_ROOT/freetype-$FREETYPE_VERSION" "$cross_file" \
        -Dharfbuzz=disabled -Dbrotli=disabled -Dbzip2=disabled -Dpng=disabled \
        -Dzlib=disabled -Dtests=disabled
    build_meson "fribidi" "$SOURCE_ROOT/fribidi-1.0.16" "$cross_file" \
        -Ddocs=false -Dbin=false -Dtests=false
    build_meson "libass" "$SOURCE_ROOT/libass-$LIBASS_VERSION" "$cross_file" \
        -Dfontconfig=disabled -Dcoretext=enabled -Ddirectwrite=disabled \
        -Dasm=disabled -Dtest=disabled -Dcompare=disabled -Dprofile=disabled \
        -Dfuzz=disabled -Dcheckasm=disabled
    build_meson "libplacebo" "$SOURCE_ROOT/libplacebo-$LIBPLACEBO_VERSION" "$cross_file" \
        -Dvulkan=disabled -Dopengl=disabled -Dd3d11=disabled -Dshaderc=disabled \
        -Dlcms=disabled -Ddemos=false -Dtests=false
    build_ffmpeg "$cross_file"
    build_meson "mpv" "$SOURCE_ROOT/mpv-0.40.0" "$cross_file" \
        -Dgpl=false -Dcplayer=false -Dlibmpv=true -Dbuild-date=false \
        -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled \
        -Dtests=false -Dfuzzers=false -Dlua=disabled -Djavascript=disabled \
        -Duchardet=disabled -Dcplugins=disabled -Dlibavdevice=disabled \
        -Dgl=enabled -Dplain-gl=enabled -Dios-gl=enabled -Dvideotoolbox-gl=disabled \
        -Dvideotoolbox-pl=disabled \
        -Daudiounit=enabled -Dcoreaudio=disabled -Davfoundation=disabled \
        -Dcocoa=disabled -Dgl-cocoa=disabled -Dswift-build=disabled \
        -Dvulkan=disabled -Degl=disabled -Dsdl2=disabled -Dx11=disabled \
        -Dwayland=disabled -Ddrm=disabled -Dvaapi=disabled -Dcuda-hwaccel=disabled
}

build_target "ios-arm64" "$IOS_SDK" "$IOS_CLANG" "$IOS_AR" "$IOS_RANLIB" "$IOS_STRIP" \
    "arm64-apple-ios$IOS_MIN_VERSION" "-miphoneos-version-min=$IOS_MIN_VERSION"
IOS_PREFIX="$PREFIX"
build_target "iossimulator-arm64" "$SIMULATOR_SDK" "$SIM_CLANG" "$SIM_AR" "$SIM_RANLIB" "$SIM_STRIP" \
    "arm64-apple-ios$IOS_MIN_VERSION-simulator" "-mios-simulator-version-min=$IOS_MIN_VERSION"
SIM_PREFIX="$PREFIX"

readonly HEADERS="$OUTPUT_ROOT/Headers"
readonly FRAMEWORK="$OUTPUT_ROOT/libmpv.xcframework"
rm -rf "$HEADERS" "$FRAMEWORK"
mkdir -p "$HEADERS" "$OUTPUT_ROOT/ios" "$OUTPUT_ROOT/iossimulator"
cp -R "$SOURCE_ROOT/mpv-0.40.0/include/mpv" "$HEADERS/"
cat > "$HEADERS/module.modulemap" <<'EOF'
module MPV {
    header "mpv/client.h"
    header "mpv/render.h"
    header "mpv/render_gl.h"
    header "mpv/stream_cb.h"
    export *
}
EOF

make_combined_archive() {
    local prefix="$1" output="$2"
    local archives=(
        "$prefix/lib/libmpv.a" "$prefix/lib/libavcodec.a" "$prefix/lib/libavfilter.a"
        "$prefix/lib/libavformat.a" "$prefix/lib/libavutil.a" "$prefix/lib/libswresample.a"
        "$prefix/lib/libswscale.a" "$prefix/lib/libass.a" "$prefix/lib/libfreetype.a"
        "$prefix/lib/libfribidi.a" "$prefix/lib/libharfbuzz.a" "$prefix/lib/libplacebo.a"
    )
    for archive in "${archives[@]}"; do [[ -f "$archive" ]] || die "missing static archive: $archive"; done
    libtool -static -o "$output" "${archives[@]}"
}

make_combined_archive "$IOS_PREFIX" "$OUTPUT_ROOT/ios/libmpv.a"
make_combined_archive "$SIM_PREFIX" "$OUTPUT_ROOT/iossimulator/libmpv.a"
xcodebuild -create-xcframework \
    -library "$OUTPUT_ROOT/ios/libmpv.a" -headers "$HEADERS" \
    -library "$OUTPUT_ROOT/iossimulator/libmpv.a" -headers "$HEADERS" \
    -output "$FRAMEWORK"

echo "Built $FRAMEWORK"
du -sh "$FRAMEWORK"

if [[ -n "$INSTALL_ROOT" ]]; then
    mkdir -p "$INSTALL_ROOT"
    rm -rf "$INSTALL_ROOT/libmpv.xcframework"
    cp -R "$FRAMEWORK" "$INSTALL_ROOT/libmpv.xcframework"
    echo "Installed $INSTALL_ROOT/libmpv.xcframework"
fi
