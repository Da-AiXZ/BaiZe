#!/bin/bash
set -euo pipefail

# build-ipa.sh — 从 xcarchive 构建 IPA
# Usage: build-ipa.sh <xcarchive-path> <output-dir>

ARCHIVE_PATH="${1:?Usage: build-ipa.sh <xcarchive-path> <output-dir>}"
OUTPUT_DIR="${2:?Usage: build-ipa.sh <xcarchive-path> <output-dir>}"
PRODUCT_NAME="Baize"
ENTITLEMENTS="Baize/Baize/Baize.entitlements"

# Prebuilt xcframework URLs for ios_system runtime dependencies
# (holzschu's GitHub releases — curl_ios needs libssh2, ssh_cmd needs openssl)
LIBSSH2_XCFRAMEWORK_URL="https://github.com/holzschu/libssh2-apple/releases/download/v1.11.0/libssh2-dynamic.xcframework.zip"
OPENSSL_XCFRAMEWORK_URL="https://github.com/holzschu/openssl-apple/releases/download/v1.1.1w/openssl-dynamic.xcframework.zip"

echo "📦 Building IPA from: $ARCHIVE_PATH"

# 1. Extract .app from xcarchive
APP_PATH="$ARCHIVE_PATH/Products/Applications/$PRODUCT_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ .app not found at $APP_PATH"
    echo "Searching for .app in archive..."
    find "$ARCHIVE_PATH" -name "*.app" -type d || true
    exit 1
fi
echo "✅ Found .app at: $APP_PATH"

# 2. Create IPA staging directory
rm -rf "$OUTPUT_DIR/ipa"
mkdir -p "$OUTPUT_DIR/ipa/Payload"
cp -r "$APP_PATH" "$OUTPUT_DIR/ipa/Payload/"

# 3. Insert runtime binaries into Frameworks/
mkdir -p "$OUTPUT_DIR/ipa/Payload/$PRODUCT_NAME.app/Frameworks"
for binary in node python3; do
    if [ -f "Baize/Baize/Frameworks/$binary" ]; then
        cp "Baize/Baize/Frameworks/$binary" "$OUTPUT_DIR/ipa/Payload/$PRODUCT_NAME.app/Frameworks/"
        echo "✅ Copied $binary to Frameworks/"
    else
        echo "⚠️ $binary not found in Baize/Baize/Frameworks/"
    fi
done

# 3b. Download and embed missing ios_system runtime dependencies (libssh2, openssl)
# These are dynamic frameworks required by curl_ios.framework and ssh_cmd.framework at runtime,
# but SPM does not automatically embed them into the IPA.
FRAMEWORKS_DIR="$OUTPUT_DIR/ipa/Payload/$PRODUCT_NAME.app/Frameworks"
XCFW_TMPDIR=$(mktemp -d)
trap 'rm -rf "$XCFW_TMPDIR"' EXIT

echo ""
echo "📦 Downloading prebuilt xcframeworks for ios_system dependencies..."

# Helper: download, unzip, extract arm64-ios slice, copy .framework to Frameworks/
embed_xcframework() {
    local name="$1"  # e.g. libssh2 or openssl
    local url="$2"  # download URL
    local zip_name="$3"  # e.g. libssh2-dynamic.xcframework.zip

    echo "  Downloading $name xcframework..."
    local zip_path="$XCFW_TMPDIR/$zip_name"
    curl -fL --retry 3 --retry-delay 5 -o "$zip_path" "$url"

    # Verify download
    local zip_size
    zip_size=$(stat -f%z "$zip_path" 2>/dev/null || stat -c%s "$zip_path" 2>/dev/null || echo 0)
    if [ "$zip_size" -lt 1000 ]; then
        echo "  ERROR: Downloaded $zip_name is only $zip_size bytes (expected several MB)"
        echo "  URL: $url"
        head -5 "$zip_path" 2>/dev/null || true
        exit 1
    fi
    echo "  Downloaded $zip_name ($(( zip_size / 1024 )) KB)"

    echo "  Unzipping $name xcframework..."
    unzip -q -o "$zip_path" -d "$XCFW_TMPDIR"

    # Find the .xcframework directory (name might differ from zip filename)
    local xcframework_dir=""
    xcframework_dir=$(find "$XCFW_TMPDIR" -maxdepth 1 -type d -name '*.xcframework' | head -n 1)

    if [ -z "$xcframework_dir" ]; then
        echo "  ERROR: No .xcframework directory found after unzipping $zip_name"
        echo "  Contents of temp dir:"
        ls -1 "$XCFW_TMPDIR" 2>/dev/null || true
        exit 1
    fi
    echo "  Found xcframework: $(basename "$xcframework_dir")"

    # Dynamically find the arm64-ios slice directory inside the xcframework.
    # Prefer pure arm64 slice over arm64e for compatibility with main binary.
    local slice_dir=""
    slice_dir=$(find "$xcframework_dir" -maxdepth 1 -type d -name 'ios-arm64' | head -n 1)
    if [ -z "$slice_dir" ]; then
        slice_dir=$(find "$xcframework_dir" -maxdepth 1 -type d -name 'ios-arm64*' | head -n 1)
    fi

    if [ -z "$slice_dir" ]; then
        echo "  ERROR: Could not find ios-arm64 slice in $(basename "$xcframework_dir")"
        echo "  Available slices:"
        ls -1 "$xcframework_dir" 2>/dev/null || true
        exit 1
    fi

    local framework_dir="$slice_dir/$name.framework"
    if [ ! -d "$framework_dir" ]; then
        echo "  ERROR: $name.framework not found at $framework_dir"
        echo "  Contents of slice:"
        ls -1 "$slice_dir" 2>/dev/null || true
        exit 1
    fi

    echo "  Found $name.framework in $(basename "$slice_dir") slice"
    cp -r "$framework_dir" "$FRAMEWORKS_DIR/"
    echo "  Copied $name.framework to Frameworks/"

    # Clean up extracted files to avoid interference with subsequent xcframeworks
    rm -rf "$xcframework_dir"
    rm -f "$zip_path"
}

embed_xcframework "libssh2" "$LIBSSH2_XCFRAMEWORK_URL" "libssh2-dynamic.xcframework.zip"
embed_xcframework "openssl"  "$OPENSSL_XCFRAMEWORK_URL"  "openssl-dynamic.xcframework.zip"

# Cleanup xcframework temp files
rm -rf "$XCFW_TMPDIR"
trap - EXIT

echo "✅ All ios_system runtime dependencies embedded"

# 4. Fakesign main executable WITH entitlements (W14 fix: sign executable, not IPA)
# ldid 2.1.5+ assertion fix: strip Xcode's signature first, then fakesign
EXECUTABLE="$OUTPUT_DIR/ipa/Payload/$PRODUCT_NAME.app/$PRODUCT_NAME"
codesign --remove-signature "$EXECUTABLE" 2>/dev/null || true
if [ -f "$ENTITLEMENTS" ]; then
    ldid -S"$ENTITLEMENTS" "$EXECUTABLE"
    echo "✅ Fakesigned main executable with entitlements"
else
    echo "⚠️ Entitlements file not found at $ENTITLEMENTS, using ad-hoc sign"
    ldid -S "$EXECUTABLE"
fi

# 5. Fakesign runtime binaries (ad-hoc, no entitlements)
# Only sign actual Mach-O binaries — skip placeholder shell scripts
# Covers both standalone binaries (node, python3) and .framework bundles (libssh2, openssl)
FW_BASE="$OUTPUT_DIR/ipa/Payload/$PRODUCT_NAME.app/Frameworks"

# 5a. Standalone binaries in Frameworks/
for binary in "$FW_BASE/"*; do
    if [ -f "$binary" ] && [ -x "$binary" ]; then
        if file "$binary" | grep -q "Mach-O"; then
            ldid -S "$binary"
            echo "✅ Fakesigned $(basename "$binary")"
        else
            echo "⚠️ Skipping $(basename "$binary") — not a Mach-O binary (placeholder)"
        fi
    fi
done

# 5b. Framework bundle binaries (e.g. libssh2.framework/libssh2)
for fw_bundle in "$FW_BASE/"*.framework; do
    if [ ! -d "$fw_bundle" ]; then
        continue
    fi
    fw_name=$(basename "$fw_bundle" .framework)
    fw_binary="$fw_bundle/$fw_name"
    if [ -f "$fw_binary" ]; then
        ldid -S "$fw_binary"
        echo "✅ Fakesigned $fw_name.framework/$fw_name"
    else
        echo "⚠️ No binary at $fw_name.framework/$fw_name — skipping"
    fi
done

# 6. Create IPA
cd "$OUTPUT_DIR/ipa"
zip -r "$PRODUCT_NAME.ipa" Payload
cd -
mkdir -p "$OUTPUT_DIR"
mv "$OUTPUT_DIR/ipa/$PRODUCT_NAME.ipa" "$OUTPUT_DIR/"
rm -rf "$OUTPUT_DIR/ipa"

echo "✅ IPA created: $OUTPUT_DIR/$PRODUCT_NAME.ipa"
ls -lh "$OUTPUT_DIR/$PRODUCT_NAME.ipa"
