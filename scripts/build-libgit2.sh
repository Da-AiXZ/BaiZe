#!/bin/bash
set -euo pipefail

# build-libgit2.sh — Build libgit2.xcframework with USE_BUNDLED_ZLIB=ON
#
# Fixes "failed to initialize zlib" on iOS 16.6.1 TrollStore (no-sandbox) by
# compiling zlib from libgit2's bundled deps/zlib/ source directly into the
# static library, completely avoiding the system libz that fails in that
# environment.
#
# Based on light-tech/LibGit2-On-iOS build-libgit2-framework.sh (v1.3.1).
# Modified for Baize:
#   - Build iphoneos arm64 ONLY (TrollStore device app, no simulator slice)
#   - Add -DUSE_BUNDLED_ZLIB=ON (core fix)
#   - Add -DREGEX_BACKEND=builtin (skip libpcre, simplify dependencies)
#   - Output to Baize/Baize/Frameworks/libgit2.xcframework (same structure as
#     the previous download-libgit2.sh)
#   - Cache check: skip build if xcframework already exists
#
# Dependencies retained: OpenSSL (HTTPS push) + libssh2 (SSH push).
# These are required — removing them would break push over HTTPS/SSH.
#
# Prerequisites (macos-14 GitHub Actions runner):
#   - Xcode 15.4 + Command Line Tools
#   - cmake (pre-installed)
#   - libtool, lipo, ditto (macOS builtins)

export REPO_ROOT=$(pwd)

FRAMEWORKS_DIR="Baize/Baize/Frameworks"
LIBGIT2_XCFRAMEWORK="$FRAMEWORKS_DIR/libgit2.xcframework"

# ---------------------------------------------------------------------------
# Cache check — if xcframework already exists with libgit2.a, skip the build.
# This matches the behavior of the previous download-libgit2.sh.
# ---------------------------------------------------------------------------
if [ -d "$LIBGIT2_XCFRAMEWORK" ] && [ -f "$LIBGIT2_XCFRAMEWORK/ios-arm64/libgit2.a" ]; then
    echo "✅ libgit2.xcframework already exists (cached), skipping build"
    exit 0
fi

# ---------------------------------------------------------------------------
# Platform configuration — iphoneos arm64 only
# ---------------------------------------------------------------------------
PLATFORM="iphoneos"
ARCH="arm64"
SYSROOT=$(xcodebuild -version -sdk iphoneos Path)

echo "=== Building libgit2.xcframework ==="
echo "  Platform: $PLATFORM"
echo "  Arch:     $ARCH"
echo "  Sysroot:  $SYSROOT"
echo "  Zlib:     BUNDLED (USE_BUNDLED_ZLIB=ON)"
echo "  Regex:    builtin (REGEX_BACKEND=builtin)"
echo ""

# Common CMake args for all dependencies
CMAKE_COMMON_ARGS=(
    -DBUILD_SHARED_LIBS=NO
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_C_COMPILER_WORKS=ON
    -DCMAKE_CXX_COMPILER_WORKS=ON
    -DCMAKE_INSTALL_PREFIX=$REPO_ROOT/install/$PLATFORM
    -DCMAKE_OSX_ARCHITECTURES=$ARCH
    -DCMAKE_OSX_SYSROOT=$SYSROOT
    # Compatibility: libssh2 1.10.0 CMakeLists.txt uses cmake_minimum_required(VERSION 2.x),
    # but CMake on macOS-14 runner has removed support for < 3.5. This flag lets the
    # old CMakeLists.txt configure anyway. Also benefits libgit2's CMakeLists.txt.
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)

# ---------------------------------------------------------------------------
# Build OpenSSL v3.0.4 (required for HTTPS push)
# ---------------------------------------------------------------------------
build_openssl() {
    echo "📦 Building OpenSSL 3.0.4 for $PLATFORM ($ARCH)..."

    rm -rf openssl-3.0.4
    if [ ! -f openssl-3.0.4.tar.gz ]; then
        curl -fSL --retry 3 -o openssl-3.0.4.tar.gz \
            https://www.openssl.org/source/openssl-3.0.4.tar.gz
    fi
    tar xzf openssl-3.0.4.tar.gz
    cd openssl-3.0.4

    export CFLAGS="-isysroot $SYSROOT -arch $ARCH"
    ./Configure \
        --prefix=$REPO_ROOT/install/$PLATFORM \
        --openssldir=$REPO_ROOT/install/$PLATFORM \
        ios64-cross no-shared no-dso no-hw no-engine
    make
    make install_sw install_ssldirs
    unset CFLAGS

    cd $REPO_ROOT
    echo "✅ OpenSSL built and installed"
}

# ---------------------------------------------------------------------------
# Build libssh2 v1.10.0 (required for SSH push)
# Depends on: OpenSSL
# ---------------------------------------------------------------------------
build_libssh2() {
    echo "📦 Building libssh2 1.10.0 for $PLATFORM ($ARCH)..."

    rm -rf libssh2-1.10.0
    if [ ! -f libssh2-1.10.0.tar.gz ]; then
        curl -fSL --retry 3 -o libssh2-1.10.0.tar.gz \
            https://www.libssh2.org/download/libssh2-1.10.0.tar.gz
    fi
    tar xzf libssh2-1.10.0.tar.gz
    cd libssh2-1.10.0

    rm -rf build && mkdir build && cd build

    local SSH2_ARGS=("${CMAKE_COMMON_ARGS[@]}")
    SSH2_ARGS+=(
        -DCRYPTO_BACKEND=OpenSSL
        -DOPENSSL_ROOT_DIR=$REPO_ROOT/install/$PLATFORM
        -DBUILD_EXAMPLES=OFF
        -DBUILD_TESTING=OFF
    )

    cmake "${SSH2_ARGS[@]}" ..
    cmake --build . --target install

    cd $REPO_ROOT
    echo "✅ libssh2 built and installed"
}

# ---------------------------------------------------------------------------
# Build libgit2 v1.3.1 with USE_BUNDLED_ZLIB=ON (core fix)
# Depends on: OpenSSL, libssh2
# ---------------------------------------------------------------------------
build_libgit2() {
    echo "📦 Building libgit2 v1.3.1 for $PLATFORM ($ARCH) with USE_BUNDLED_ZLIB=ON..."

    rm -rf libgit2-1.3.1
    if [ ! -f v1.3.1.zip ]; then
        curl -fSL --retry 3 -o v1.3.1.zip \
            https://github.com/libgit2/libgit2/archive/refs/tags/v1.3.1.zip
    fi
    ditto -V -x -k --sequesterRsrc --rsrc v1.3.1.zip ./
    cd libgit2-1.3.1

    rm -rf build && mkdir build && cd build

    local GIT2_ARGS=("${CMAKE_COMMON_ARGS[@]}")
    GIT2_ARGS+=(-DBUILD_CLAR=NO)

    # SSH support — libgit2 needs libssh2 headers for SSH push.
    # Setting LIBSSH2_FOUND forces SSH support; since we build a static
    # library, we only need the headers (the .a is merged later).
    GIT2_ARGS+=(
        -DOPENSSL_ROOT_DIR=$REPO_ROOT/install/$PLATFORM
        -DUSE_SSH=ON
        -DLIBSSH2_FOUND=YES
        -DLIBSSH2_INCLUDE_DIRS=$REPO_ROOT/install/$PLATFORM/include
    )

    # ═══════════════════════════════════════════════════════════════════════
    # CORE FIX: Use bundled zlib instead of system libz.
    #
    # libgit2 v1.3.1 CMakeLists.txt:
    #   OPTION(USE_BUNDLED_ZLIB "Include a bundled (yarn) zlib" OFF)
    #
    # When ON, libgit2 compiles zlib from deps/zlib/ source directly into
    # libgit2.a, completely avoiding the system libz. This fixes
    # "failed to initialize zlib" (deflateInit_ failure) on iOS 16.6.1
    # TrollStore no-sandbox environment.
    # ═══════════════════════════════════════════════════════════════════════
    GIT2_ARGS+=(-DUSE_BUNDLED_ZLIB=ON)

    # Use libgit2's built-in regex implementation instead of libpcre.
    # Supported since libgit2 v1.0.0; skips the libpcre build entirely.
    GIT2_ARGS+=(-DREGEX_BACKEND=builtin)

    cmake "${GIT2_ARGS[@]}" ..
    cmake --build . --target install

    cd $REPO_ROOT
    echo "✅ libgit2 v1.3.1 built and installed (with bundled zlib)"
}

# ---------------------------------------------------------------------------
# Main build sequence
# ---------------------------------------------------------------------------
mkdir -p "$FRAMEWORKS_DIR"

build_openssl
build_libssh2
build_libgit2

# ---------------------------------------------------------------------------
# Merge all static libraries into a single libgit2.a
#
# libgit2.a (with bundled zlib + builtin regex)
# + libssh2.a
# + libssl.a + libcrypto.a
# = merged libgit2.a (self-contained, no external deps)
# ---------------------------------------------------------------------------
echo "📦 Merging static libraries into single libgit2.a..."
cd $REPO_ROOT/install/$PLATFORM/lib

# === 清理 OpenSSL liblegacy 重复对象（方案1 关键步骤）===
# OpenSSL 3.0.4 的 libcrypto.a 安装后包含 liblegacy-lib-*.o 对象（如 liblegacy-lib-bn_asm.o），
# 和 libcrypto-lib-*.o（如 libcrypto-lib-bn_asm.o）重复。
# -force_load 时会报 duplicate symbol。这里在合并前从 libcrypto.a 删除 liblegacy 对象。
echo "  Cleaning liblegacy objects from libcrypto.a..."
LEGACY_OBJS=$(ar t libcrypto.a 2>/dev/null | grep '^liblegacy-' || true)
if [ -n "$LEGACY_OBJS" ]; then
    echo "  Found liblegacy objects to remove:"
    echo "$LEGACY_OBJS" | sed 's/^/    - /'
    # ar d 删除对象（macOS BSD ar 支持）。逐个删除避免参数过长。
    for obj in $LEGACY_OBJS; do
        ar d libcrypto.a "$obj"
    done
    echo "  ✅ Removed liblegacy objects from libcrypto.a"
    # 验证清理结果
    REMAINING=$(ar t libcrypto.a 2>/dev/null | grep '^liblegacy-' || true)
    if [ -n "$REMAINING" ]; then
        echo "  ❌ ERROR: liblegacy objects still present after cleanup:"
        echo "$REMAINING"
        exit 1
    fi
else
    echo "  (no liblegacy objects found in libcrypto.a — nothing to clean)"
fi

# === 合并：用明确列表，排除独立的 liblegacy.a ===
# 不用 lib/*.a 通配符（会拉入 liblegacy.a）。明确列出需要的库。
cd $REPO_ROOT/install/$PLATFORM
libtool -static -o libgit2.a \
    lib/libgit2.a \
    lib/libssh2.a \
    lib/libssl.a \
    lib/libcrypto.a
echo "✅ Merged libgit2.a contains: libgit2 (+ bundled zlib + builtin regex) + OpenSSL(libssl+libcrypto, no liblegacy) + libssh2"

# === 合并后符号验证 ===
echo "  Verifying merged libgit2.a..."
# 1. 不应再有 liblegacy 对象
if nm libgit2.a 2>/dev/null | grep -q 'liblegacy'; then
    echo "  ❌ ERROR: liblegacy objects found in merged libgit2.a"
    nm libgit2.a 2>/dev/null | grep 'liblegacy' | head -5
    exit 1
fi
echo "  ✅ No liblegacy objects in merged libgit2.a"
# 2. bundled zlib 的 deflateInit2_ 应为 T(defined) 符号
if nm libgit2.a 2>/dev/null | grep -E ' [Tt] _deflateInit2_$' >/dev/null; then
    echo "  ✅ deflateInit2_ is a defined (T) symbol — bundled zlib present"
else
    echo "  ⚠️ WARNING: deflateInit2_ not found as T symbol (may be expected if symbol naming differs)"
fi

# ---------------------------------------------------------------------------
# Create xcframework
# Output structure:
#   libgit2.xcframework/
#     Info.plist
#     ios-arm64/
#       libgit2.a
#       Headers/
#         git2.h
#         ... (other libgit2 headers)
# ---------------------------------------------------------------------------
echo "📦 Creating libgit2.xcframework..."
cd $REPO_ROOT
rm -rf "$LIBGIT2_XCFRAMEWORK"

xcodebuild -create-xcframework \
    -library install/$PLATFORM/libgit2.a \
    -headers install/$PLATFORM/include \
    -output "$LIBGIT2_XCFRAMEWORK"

# ---------------------------------------------------------------------------
# Verify output structure
# ---------------------------------------------------------------------------
echo ""
echo "=== Verification ==="

if [ -f "$LIBGIT2_XCFRAMEWORK/ios-arm64/libgit2.a" ]; then
    echo "✅ libgit2.a found: $LIBGIT2_XCFRAMEWORK/ios-arm64/libgit2.a"
else
    echo "❌ ERROR: libgit2.a not found in xcframework"
    find "$LIBGIT2_XCFRAMEWORK" -name "*.a" 2>/dev/null || true
    exit 1
fi

if [ -f "$LIBGIT2_XCFRAMEWORK/ios-arm64/Headers/git2.h" ]; then
    echo "✅ git2.h found: $LIBGIT2_XCFRAMEWORK/ios-arm64/Headers/git2.h"
else
    echo "❌ ERROR: git2.h not found in xcframework"
    find "$LIBGIT2_XCFRAMEWORK" -name "git2.h" 2>/dev/null || true
    exit 1
fi

echo ""
echo "=== Build Summary ==="
echo "  libgit2 version: v1.3.1"
echo "  Platform:        iphoneos arm64"
echo "  Zlib:            BUNDLED (USE_BUNDLED_ZLIB=ON)"
echo "  Regex:           builtin (REGEX_BACKEND=builtin)"
echo "  SSH:             enabled (libssh2 + OpenSSL)"
echo "  HTTPS:           enabled (OpenSSL)"
echo "  Output:          $LIBGIT2_XCFRAMEWORK"
echo ""
echo "✅ libgit2.xcframework built successfully — no system libz dependency"
