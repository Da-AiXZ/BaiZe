#!/bin/bash
set -euo pipefail

# download-libgit2.sh — Download libgit2.xcframework from light-tech/LibGit2-On-iOS
# This xcframework bundles libgit2 v1.3.1 + OpenSSL v3.0.4 + libssh2 + libpcre
# (all dependencies are statically linked into a single framework).
#
# Source: https://github.com/light-tech/LibGit2-On-iOS/releases/tag/v1.3.1
# License: Public domain (usage subject to libgit2/openssl/libssh2/libpcre licenses)

FRAMEWORKS_DIR="Baize/Baize/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

LIBGIT2_XCFRAMEWORK="$FRAMEWORKS_DIR/libgit2.xcframework"

if [ -d "$LIBGIT2_XCFRAMEWORK" ]; then
    echo "✅ libgit2.xcframework already exists"
    exit 0
fi

echo "📥 Downloading libgit2.xcframework v1.3.1 from light-tech/LibGit2-On-iOS..."

LIBGIT2_URL="https://github.com/light-tech/LibGit2-On-iOS/releases/download/v1.3.1/libgit2.xcframework.zip"
curl -fL --retry 3 --retry-delay 5 -o /tmp/libgit2.xcframework.zip "$LIBGIT2_URL"

# Verify download
ZIP_SIZE=$(stat -f%z /tmp/libgit2.xcframework.zip 2>/dev/null || stat -c%s /tmp/libgit2.xcframework.zip 2>/dev/null || echo 0)
if [ "$ZIP_SIZE" -lt 5000000 ]; then
    echo "❌ ERROR: Downloaded file is only $ZIP_SIZE bytes (expected ~19MB)"
    rm -f /tmp/libgit2.xcframework.zip
    exit 1
fi
echo "   Downloaded $(( ZIP_SIZE / 1024 )) KB"

echo "📂 Extracting libgit2.xcframework..."
unzip -q -o /tmp/libgit2.xcframework.zip -d /tmp/libgit2-extract

# Find libgit2.xcframework in extracted contents
EXTRACTED_XCFW=$(find /tmp/libgit2-extract -maxdepth 1 -type d -name "libgit2.xcframework" | head -n 1)
if [ -n "$EXTRACTED_XCFW" ]; then
    cp -r "$EXTRACTED_XCFW" "$FRAMEWORKS_DIR/"
    echo "✅ libgit2.xcframework extracted to $FRAMEWORKS_DIR/"
else
    echo "❌ ERROR: libgit2.xcframework not found in zip"
    echo "   Contents of extracted directory:"
    ls -1 /tmp/libgit2-extract/ 2>/dev/null || true
    rm -f /tmp/libgit2.xcframework.zip
    rm -rf /tmp/libgit2-extract
    exit 1
fi

# Verify xcframework structure — check for git2.h header and framework binary
GIT2_H_FOUND=""
LIBGIT2_BINARY_FOUND=""
for slice_dir in "$LIBGIT2_XCFRAMEWORK"/*/; do
    [ -d "$slice_dir" ] || continue
    # Check for libgit2.framework structure
    if [ -d "$slice_dir/libgit2.framework" ]; then
        if [ -f "$slice_dir/libgit2.framework/Headers/git2.h" ]; then
            GIT2_H_FOUND="$slice_dir/libgit2.framework/Headers/git2.h"
        fi
        if [ -f "$slice_dir/libgit2.framework/libgit2" ]; then
            LIBGIT2_BINARY_FOUND="$slice_dir/libgit2.framework/libgit2"
        fi
    fi
    # Some builds may use a different framework name
    for fw_dir in "$slice_dir"/*.framework; do
        [ -d "$fw_dir" ] || continue
        fw_name=$(basename "$fw_dir" .framework)
        if [ -f "$fw_dir/Headers/git2.h" ]; then
            GIT2_H_FOUND="$fw_dir/Headers/git2.h"
        fi
        if [ -f "$fw_dir/$fw_name" ]; then
            LIBGIT2_BINARY_FOUND="$fw_dir/$fw_name"
        fi
    done
done

if [ -n "$GIT2_H_FOUND" ]; then
    echo "✅ git2.h found: $GIT2_H_FOUND"
else
    echo "⚠️ WARNING: git2.h not found in libgit2.xcframework"
    echo "   Searching for git2.h..."
    find "$LIBGIT2_XCFRAMEWORK" -name "git2.h" 2>/dev/null || true
fi

if [ -n "$LIBGIT2_BINARY_FOUND" ]; then
    echo "✅ libgit2 binary found: $LIBGIT2_BINARY_FOUND"
else
    echo "⚠️ WARNING: libgit2 binary not found in xcframework"
    echo "   Framework directories found:"
    find "$LIBGIT2_XCFRAMEWORK" -name "*.framework" -type d 2>/dev/null || true
fi

# Clean up
rm -f /tmp/libgit2.xcframework.zip
rm -rf /tmp/libgit2-extract

echo ""
echo "=== libgit2.xcframework ==="
ls -la "$LIBGIT2_XCFRAMEWORK/"
echo ""
echo "✅ libgit2: libgit2.xcframework v1.3.1 (light-tech, includes OpenSSL + libssh2 + libpcre)"
