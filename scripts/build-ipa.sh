#!/bin/bash
set -euo pipefail

# build-ipa.sh — 从 xcarchive 构建 IPA
# Usage: build-ipa.sh <xcarchive-path> <output-dir>

ARCHIVE_PATH="${1:?Usage: build-ipa.sh <xcarchive-path> <output-dir>}"
OUTPUT_DIR="${2:?Usage: build-ipa.sh <xcarchive-path> <output-dir>}"
PRODUCT_NAME="Baize"
ENTITLEMENTS="Baize/Baize/Baize.entitlements"

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

# 4. Fakesign main executable WITH entitlements (W14 fix: sign executable, not IPA)
if [ -f "$ENTITLEMENTS" ]; then
    ldid -S"$ENTITLEMENTS" "$OUTPUT_DIR/ipa/Payload/$PRODUCT_NAME.app/$PRODUCT_NAME"
    echo "✅ Fakesigned main executable with entitlements"
else
    echo "⚠️ Entitlements file not found at $ENTITLEMENTS, using ad-hoc sign"
    ldid -S "$OUTPUT_DIR/ipa/Payload/$PRODUCT_NAME.app/$PRODUCT_NAME"
fi

# 5. Fakesign runtime binaries (ad-hoc, no entitlements)
for binary in "$OUTPUT_DIR/ipa/Payload/$PRODUCT_NAME.app/Frameworks/"*; do
    if [ -f "$binary" ] && [ -x "$binary" ]; then
        ldid -S "$binary"
        echo "✅ Fakesigned $(basename "$binary")"
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
