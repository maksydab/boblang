#!/usr/bin/env bash
set -eu

ZIG_VERSION="0.13.0"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$BUILD_DIR/zig-out"
DIST_DIR="$BUILD_DIR/dist"
CACHE_DIR="$DIST_DIR/.cache"

download_zig() {
    local label="$1"
    local archive="$2"
    local subdir="${archive%.tar.*}"
    subdir="${subdir%.zip}"

    local cached="$CACHE_DIR/$archive"
    mkdir -p "$CACHE_DIR"

    if [ ! -f "$cached" ]; then
        echo "  downloading zig ($archive) ..." >&2
        curl -sL "https://ziglang.org/download/$ZIG_VERSION/$archive" -o "$cached"
    fi

    local extract_dir="$CACHE_DIR/$label"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    if echo "$archive" | grep -q '\.zip$'; then
        unzip -o "$cached" -d "$extract_dir" > /dev/null 2>&1
    else
        tar xf "$cached" -C "$extract_dir" 2>/dev/null
    fi
    local zig_bin
    zig_bin="$(find "$extract_dir" -name 'zig' -o -name 'zig.exe' 2>/dev/null | head -1)"
    echo "$zig_bin"
}

bundle_platform() {
    local target="$1"
    local label="$2"
    local ext="${3:-}"
    local zig_archive="$4"
    local zig_bin_name="${5:-zig}"

    echo "==> Building for $label ($target) ..."

    rm -rf "$OUT_DIR"
    zig build -Doptimize=ReleaseFast -Dtarget="$target" 2>&1
    local zig_path
    zig_path="$(download_zig "$label" "$zig_archive")"
    local zig_dir
    zig_dir="$(dirname "$zig_path")"
    local plat_dir="$DIST_DIR/$label"
    rm -rf "$plat_dir"
    mkdir -p "$plat_dir/lib/zig/lib"

    cp "$OUT_DIR/bin/boblang$ext" "$plat_dir/boblang$ext"
    cp "$zig_path" "$plat_dir/lib/zig/$zig_bin_name"
    chmod 755 "$plat_dir/lib/zig/$zig_bin_name" 2>/dev/null || true
    if [ -d "$zig_dir/lib" ]; then
        cp -r "$zig_dir/lib/"* "$plat_dir/lib/zig/lib/"
    fi

    # Bundle the persistent build daemon (only produced for native host builds)
    # plus the full shared-library closure it links against, so the end machine
    # needs nothing beyond the base glibc. The daemon is linked with an
    # inherited DT_RPATH=$ORIGIN/lib, so it finds these libs next to itself.
    if [ -f "$OUT_DIR/bin/boblangd" ]; then
        cp "$OUT_DIR/bin/boblangd" "$plat_dir/boblangd"
        chmod 755 "$plat_dir/boblangd"
        mkdir -p "$plat_dir/lib"
        for lib in $(ldd "$OUT_DIR/bin/boblangd" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*'); do
            case "$(basename "$lib")" in
                libc.so*|libm.so*|libpthread*|libdl.so*|libutil.so*|librt.so*|libnsl.so*|libresolv.so*|libanl.so*|libBrokenLocale*|ld-linux*)
                    ;; # provided by the base glibc
                *)
                    cp -n "$lib" "$plat_dir/lib/" 2>/dev/null || true
                    ;;
            esac
        done
    fi

    if echo "$target" | grep -q linux; then
        strip "$plat_dir/boblang$ext" 2>/dev/null || true
    fi

    echo "    -> $plat_dir/  ($(du -sh "$plat_dir" | cut -f1))"
}

case "${1:-all}" in
    linux)
        bundle_platform "x86_64-linux-gnu" "linux-x86_64" "" \
            "zig-linux-x86_64-$ZIG_VERSION.tar.xz" "zig"
        ;;
    windows)
        bundle_platform "x86_64-windows-gnu" "windows-x86_64" ".exe" \
            "zig-windows-x86_64-$ZIG_VERSION.zip" "zig.exe"
        ;;
    macos)
        bundle_platform "x86_64-macos-none" "macos-x86_64" "" \
            "zig-macos-x86_64-$ZIG_VERSION.tar.xz" "zig"
        bundle_platform "aarch64-macos-none" "macos-arm64" "" \
            "zig-macos-aarch64-$ZIG_VERSION.tar.xz" "zig"
        ;;
    all)
        bundle_platform "x86_64-linux-gnu" "linux-x86_64" "" \
            "zig-linux-x86_64-$ZIG_VERSION.tar.xz" "zig"
        bundle_platform "x86_64-windows-gnu" "windows-x86_64" ".exe" \
            "zig-windows-x86_64-$ZIG_VERSION.zip" "zig.exe"
        bundle_platform "x86_64-macos-none" "macos-x86_64" "" \
            "zig-macos-x86_64-$ZIG_VERSION.tar.xz" "zig"
        bundle_platform "aarch64-macos-none" "macos-arm64" "" \
            "zig-macos-aarch64-$ZIG_VERSION.tar.xz" "zig"
        ;&
    arch)
        bundle_platform "x86_64-linux-gnu" "linux-x86_64" "" \
            "zig-linux-x86_64-$ZIG_VERSION.tar.xz" "zig"
        echo "==> Creating Arch package source tarball ..."
        mkdir -p "$DIST_DIR/linux-x86_64-arch"
        tar czf "$DIST_DIR/linux-x86_64-arch/boblang-linux-x86_64.tar.gz" \
            -C "$DIST_DIR/linux-x86_64" .
        echo "    -> dist/linux-x86_64-arch/boblang-linux-x86_64.tar.gz"
        echo "    -> cd dist/linux-x86_64-arch && makepkg"
        ;;
    *)
        echo "Usage: $0 [linux|windows|macos|arch|all]"
        echo ""
        echo "  linux       Build Linux dist bundle only"
        echo "  windows     Build Windows dist bundle only"
        echo "  macos       Build macOS dist bundles (Intel + ARM)"
        echo "  arch        Create Arch PKGBUILD source tarball (requires linux built first)"
        echo "  all         Build all platform dist bundles + Arch package"
        exit 1
        ;;
esac

rm -rf "$CACHE_DIR"
echo "==> Done."
