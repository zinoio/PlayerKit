#!/usr/bin/env bash
# build_libass.sh — Build libass (+ freetype + fribidi + harfbuzz)
# xcframeworks for iOS / tvOS / macOS, mirroring build_ffmpeg.sh's
# slice → lipo → xcframework pipeline (zyno#158 ASS subtitle rendering).
#
# Usage:
#   ./scripts/build_libass.sh            # full build, all 8 slices
#   FAST=1 ./scripts/build_libass.sh     # macOS arm64 slice only (dev iteration)
#
# Output: Sources/CAss/xcframeworks/{libass,libfreetype,libfribidi,libharfbuzz}.xcframework
#         Sources/CAss/include/ass/     (headers Swift consumes via CAss)
#
# harfbuzz is NOT optional: libass ≥ 0.17 requires it unconditionally at
# configure time.  Built as a pure core (no glib/cairo/icu/freetype) — it
# only shapes; freetype rasterizes.  Bonus: Arabic/Indic complex scripts
# shape correctly.
# Font provider: libass auto-detects CoreText on Darwin (no fontconfig).

set -eo pipefail

FREETYPE_VERSION="${FREETYPE_VERSION:-2.13.3}"
FRIBIDI_VERSION="${FRIBIDI_VERSION:-1.0.16}"
HARFBUZZ_VERSION="${HARFBUZZ_VERSION:-8.5.0}"
LIBASS_VERSION="${LIBASS_VERSION:-0.17.3}"

MIN_IOS="${MIN_IOS:-17.0}"
MIN_TVOS="${MIN_TVOS:-17.0}"
MIN_MACOS="${MIN_MACOS:-14.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PACKAGE_DIR/Sources/CAss"
BUILD_DIR="${TMPDIR:-/tmp}/libass-build-$$"
SRC_DIR="$BUILD_DIR/src"

XCFW_DIR="$OUTPUT_DIR/xcframeworks"
HEADERS_DIR="$OUTPUT_DIR/include"

CACHE_DIR="${CACHE_DIR:-}"

# freetype publishes no GitHub release assets; the Savannah gateway redirects
# to a random mirror and some of those (ftp.cc.uoc.gr) time out — try mirrors
# directly, in order of measured reliability.
FREETYPE_TARBALL="freetype-${FREETYPE_VERSION}.tar.xz"
FREETYPE_URLS=(
  "https://mirror.netcologne.de/savannah/freetype/${FREETYPE_TARBALL}"
  "https://mirror.csclub.uwaterloo.ca/nongnu/freetype/${FREETYPE_TARBALL}"
  "https://downloads.sourceforge.net/project/freetype/freetype2/${FREETYPE_VERSION}/${FREETYPE_TARBALL}"
)
FRIBIDI_TARBALL="fribidi-${FRIBIDI_VERSION}.tar.xz"
FRIBIDI_URL="https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/${FRIBIDI_TARBALL}"
HARFBUZZ_TARBALL="harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
HARFBUZZ_URL="https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/${HARFBUZZ_TARBALL}"
LIBASS_TARBALL="libass-${LIBASS_VERSION}.tar.gz"
LIBASS_URL="https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/${LIBASS_TARBALL}"

# ── helpers ────────────────────────────────────────────────────────────────

log() { echo "▶ $*"; }

# download <tarball> <dest> <url>... — first mirror that delivers wins.
download() {
  local tarball="$1" dest="$2"; shift 2
  if [[ -n "$CACHE_DIR" && -f "$CACHE_DIR/$tarball" ]]; then
    log "Using cached $tarball"
    cp "$CACHE_DIR/$tarball" "$dest"
    return
  fi
  log "Downloading $tarball..."
  local url
  for url in "$@"; do
    # -C - + --retry-all-errors: resume across transient resets instead of
    # restarting (observed: mirrors reset mid-transfer on flaky networks).
    if curl -fL -C - --retry 8 --retry-all-errors --retry-delay 2 \
         --connect-timeout 20 --max-time 600 --progress-bar "$url" -o "$dest"; then
      if [[ -n "$CACHE_DIR" ]]; then
        mkdir -p "$CACHE_DIR"
        cp "$dest" "$CACHE_DIR/"
      fi
      return
    fi
    log "  failed: $url — trying next mirror"
    rm -f "$dest"
  done
  echo "ERROR: all mirrors failed for $tarball" >&2
  return 1
}

# ── per-slice build ────────────────────────────────────────────────────────
# Same slice table as build_ffmpeg.sh; every dep installs into the SAME
# per-slice prefix so libass's pkg-config finds freetype/fribidi.

build_slice() {
  local sdk="$1" arch="$2"
  local prefix="$BUILD_DIR/install/${sdk}-${arch}"

  local sysroot cc cxx
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  cc="$(xcrun --sdk "$sdk" --find clang)"
  cxx="$(xcrun --sdk "$sdk" --find clang++)"

  local base_cflags="-arch ${arch} -isysroot ${sysroot} -O2"
  local base_ldflags="-arch ${arch} -isysroot ${sysroot}"

  case "$sdk" in
    iphoneos)
      base_cflags+=" -mios-version-min=${MIN_IOS}"
      base_ldflags+=" -mios-version-min=${MIN_IOS}" ;;
    iphonesimulator)
      base_cflags+=" -mios-simulator-version-min=${MIN_IOS}"
      base_ldflags+=" -mios-simulator-version-min=${MIN_IOS}" ;;
    appletvos)
      base_cflags+=" -mtvos-version-min=${MIN_TVOS}"
      base_ldflags+=" -mtvos-version-min=${MIN_TVOS}" ;;
    appletvsimulator)
      base_cflags+=" -mtvos-simulator-version-min=${MIN_TVOS}"
      base_ldflags+=" -mtvos-simulator-version-min=${MIN_TVOS}" ;;
    macosx)
      base_cflags+=" -mmacosx-version-min=${MIN_MACOS}"
      base_ldflags+=" -mmacosx-version-min=${MIN_MACOS}" ;;
  esac

  # C++ 的部署目标必须跟随 case 补完的 base_cflags——在 case 之前拷贝会
  # 丢掉 -m*-version-min,harfbuzz 的 C++ 对象就会按 SDK 默认(26.0)编译,
  # 链接期报 "built for newer macOS than being linked"。
  local base_cxxflags="${base_cflags}"

  local host
  case "$arch" in
    arm64)  host="aarch64-apple-darwin" ;;
    x86_64) host="x86_64-apple-darwin" ;;
  esac

  # freetype compiles its apinames host tool with a BARE clang (no -isysroot,
  # no xcrun) — without SDKROOT that clang resolves no default sysroot and
  # dies on "stdio.h not found". Target compiles carry explicit -isysroot, so
  # SDKROOT only fixes the host tool.
  local macos_sdk
  macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
  export SDKROOT="$macos_sdk"

  mkdir -p "$prefix"

  # ── freetype (rasterizer; required by libass) ─────────────────────────
  log "[${sdk}-${arch}] freetype ${FREETYPE_VERSION}..."
  (
    cd "$BUILD_DIR/freetype"
    ./configure \
      --prefix="$prefix" --host="$host" \
      CC="$cc" CFLAGS="$base_cflags" LDFLAGS="$base_ldflags" \
      --enable-static --disable-shared \
      --with-zlib=no --with-bzip2=no --with-png=no \
      --with-brotli=no --with-harfbuzz=no \
      >/dev/null
    make -j"$(sysctl -n hw.logicalcpu)" >/dev/null
    make install >/dev/null
    make distclean >/dev/null
  )

  # ── fribidi (bidi; required by libass) ────────────────────────────────
  log "[${sdk}-${arch}] fribidi ${FRIBIDI_VERSION}..."
  (
    cd "$BUILD_DIR/fribidi"
    ./configure \
      --prefix="$prefix" --host="$host" \
      CC="$cc" CFLAGS="$base_cflags" LDFLAGS="$base_ldflags" \
      --enable-static --disable-shared \
      --disable-debug --disable-deprecated --disable-documentation \
      >/dev/null
    make -j"$(sysctl -n hw.logicalcpu)" >/dev/null
    make install >/dev/null
    make distclean >/dev/null
  )

  # ── harfbuzz (shaper; hard requirement of libass ≥ 0.17) ───────────────
  log "[${sdk}-${arch}] harfbuzz ${HARFBUZZ_VERSION}..."
  (
    cd "$BUILD_DIR/harfbuzz"
    ./configure \
      --prefix="$prefix" --host="$host" \
      CC="$cc" CXX="$cxx" \
      CFLAGS="$base_cflags" CXXFLAGS="$base_cxxflags" \
      LDFLAGS="$base_ldflags" \
      --enable-static --disable-shared \
      --with-freetype=no --with-glib=no --with-gobject=no \
      --with-cairo=no --with-icu=no --with-coretext=no \
      --disable-gtk-doc \
      >/dev/null
    make -j"$(sysctl -n hw.logicalcpu)" >/dev/null
    make install >/dev/null
    make distclean >/dev/null
  )

  # ── libass (the renderer) ──────────────────────────────────────────────
  log "[${sdk}-${arch}] libass ${LIBASS_VERSION}..."
  (
    cd "$BUILD_DIR/libass"
    # PKG_CONFIG_LIBDIR (not PATH — that APPENDS to the system search, and
    # Homebrew's harfbuzz.pc then leaks in and builds the shaper against a
    # library we don't ship).  LIBDIR replaces the search entirely.
    PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
    PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" \
    ./configure \
      --prefix="$prefix" --host="$host" \
      CC="$cc" CFLAGS="$base_cflags" LDFLAGS="$base_ldflags" \
      --enable-static --disable-shared \
      --disable-fontconfig --disable-libunibreak \
      >/dev/null
    make -j"$(sysctl -n hw.logicalcpu)" >/dev/null
    make install >/dev/null
    make distclean >/dev/null
  )

  log "[${sdk}-${arch}] done → $prefix"
}

# ── fat slices + xcframeworks (mirrors build_ffmpeg.sh) ───────────────────

lipo_libs() {
  local out_dir="$1"; shift
  local in_dirs=("$@")

  mkdir -p "$out_dir/lib" "$out_dir/include"
  cp -r "${in_dirs[0]}/include/." "$out_dir/include/"

  for lib in "${in_dirs[0]}"/lib/*.a; do
    local name
    name="$(basename "$lib")"
    local inputs=()
    for d in "${in_dirs[@]}"; do
      [[ -f "$d/lib/$name" ]] && inputs+=("$d/lib/$name")
    done
    if [[ ${#inputs[@]} -eq 1 ]]; then
      cp "${inputs[0]}" "$out_dir/lib/$name"
    else
      lipo -create "${inputs[@]}" -output "$out_dir/lib/$name"
    fi
  done
}

make_xcframework() {
  local lib_name="$1"; shift
  local slice_dirs=("$@")
  local xcfw="$XCFW_DIR/${lib_name}.xcframework"

  local args=()
  for d in "${slice_dirs[@]}"; do
    args+=(-library "$d/lib/${lib_name}.a")
  done

  rm -rf "$xcfw"
  xcodebuild -create-xcframework "${args[@]}" -output "$xcfw" >/dev/null
  log "Created ${lib_name}.xcframework"
}

# ── main ───────────────────────────────────────────────────────────────────

main() {
  log "freetype ${FREETYPE_VERSION} + fribidi ${FRIBIDI_VERSION} + libass ${LIBASS_VERSION} → ${XCFW_DIR}"
  mkdir -p "$BUILD_DIR" "$XCFW_DIR" "$HEADERS_DIR"

  for name in freetype fribidi harfbuzz libass; do
    mkdir -p "$BUILD_DIR/$name"
  done
  download "$FREETYPE_TARBALL" "$BUILD_DIR/freetype.tar.xz" "${FREETYPE_URLS[@]}"
  download "$FRIBIDI_TARBALL"  "$BUILD_DIR/fribidi.tar.xz"  "$FRIBIDI_URL"
  download "$HARFBUZZ_TARBALL" "$BUILD_DIR/harfbuzz.tar.xz" "$HARFBUZZ_URL"
  download "$LIBASS_TARBALL"   "$BUILD_DIR/libass.tar.gz"   "$LIBASS_URL"

  tar -xf "$BUILD_DIR/freetype.tar.xz" -C "$BUILD_DIR/freetype" --strip-components=1
  tar -xf "$BUILD_DIR/fribidi.tar.xz"  -C "$BUILD_DIR/fribidi"  --strip-components=1
  tar -xf "$BUILD_DIR/harfbuzz.tar.xz" -C "$BUILD_DIR/harfbuzz" --strip-components=1
  tar -xzf "$BUILD_DIR/libass.tar.gz"  -C "$BUILD_DIR/libass"   --strip-components=1

  # ── compile slices ──────────────────────────────────────────────────────
  if [[ "${FAST:-}" == "1" ]]; then
    log "FAST=1 → macosx arm64 slice only"
    build_slice macosx arm64
    SLICES=("macosx-arm64")
  else
    build_slice iphoneos         arm64
    build_slice iphonesimulator  arm64
    build_slice iphonesimulator  x86_64
    build_slice appletvos        arm64
    build_slice appletvsimulator arm64
    build_slice appletvsimulator x86_64
    build_slice macosx           arm64
    build_slice macosx           x86_64

    # ── lipo simulator / macOS fat slices ─────────────────────────────────
    local ios_sim_fat="$BUILD_DIR/install/iphonesimulator-fat"
    lipo_libs "$ios_sim_fat" \
      "$BUILD_DIR/install/iphonesimulator-arm64" \
      "$BUILD_DIR/install/iphonesimulator-x86_64"

    local tvos_sim_fat="$BUILD_DIR/install/appletvsimulator-fat"
    lipo_libs "$tvos_sim_fat" \
      "$BUILD_DIR/install/appletvsimulator-arm64" \
      "$BUILD_DIR/install/appletvsimulator-x86_64"

    local mac_fat="$BUILD_DIR/install/macosx-fat"
    lipo_libs "$mac_fat" \
      "$BUILD_DIR/install/macosx-arm64" \
      "$BUILD_DIR/install/macosx-x86_64"

    SLICES=("iphoneos-arm64" "iphonesimulator-fat" "appletvos-arm64" "appletvsimulator-fat" "macosx-fat")
  fi

  # ── xcframeworks ────────────────────────────────────────────────────────
  local slice_dirs=()
  for s in "${SLICES[@]}"; do
    slice_dirs+=("$BUILD_DIR/install/$s")
  done
  for lib in libass libfreetype libfribidi libharfbuzz; do
    make_xcframework "$lib" "${slice_dirs[@]}"
  done

  # ── Swift-facing headers: only the libass API ───────────────────────────
  log "Copying ass headers..."
  rm -rf "$HEADERS_DIR"
  mkdir -p "$HEADERS_DIR/ass"
  cp "$BUILD_DIR/install/${SLICES[0]}/include/ass/ass.h" \
     "$BUILD_DIR/install/${SLICES[0]}/include/ass/ass_types.h" \
     "$HEADERS_DIR/ass/"

  rm -rf "$BUILD_DIR"

  log "Done. Xcframeworks in: $XCFW_DIR"
  log "Headers in:           $HEADERS_DIR"
}

main "$@"
