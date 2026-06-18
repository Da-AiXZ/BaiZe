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

# 3c. Ensure NodeMobile.framework is embedded
# Declared as embed:true in project.yml, Xcode should embed it during archive.
# Verify and fallback-copy from source if missing.
NODEMOBILE_FW_APP="$OUTPUT_DIR/ipa/Payload/$PRODUCT_NAME.app/Frameworks/NodeMobile.framework"
if [ ! -d "$NODEMOBILE_FW_APP" ]; then
    echo "⚠️ NodeMobile.framework not found in .app, copying from source..."
    if [ -d "Baize/Baize/Frameworks/NodeMobile.framework" ]; then
        cp -r "Baize/Baize/Frameworks/NodeMobile.framework" "$FRAMEWORKS_DIR/"
        echo "✅ Copied NodeMobile.framework to Frameworks/"
    else
        echo "❌ ERROR: NodeMobile.framework not found in source!"
        echo "   Run scripts/download-runtime.sh first."
        exit 1
    fi
else
    echo "✅ NodeMobile.framework already embedded by Xcode"
fi

# 3d. Ensure Python.framework is embedded
# Declared as embed:true in project.yml, Xcode should embed it during archive.
# Verify and fallback-copy from xcframework if missing.
PYTHON_FW_APP="$OUTPUT_DIR/ipa/Payload/$PRODUCT_NAME.app/Frameworks/Python.framework"
if [ ! -d "$PYTHON_FW_APP" ]; then
    echo "⚠️ Python.framework not found in .app, copying from xcframework..."
    PYTHON_XCFW="Baize/Baize/Frameworks/Python.xcframework"
    if [ -d "$PYTHON_XCFW" ]; then
        # Find the arm64-ios slice and extract Python.framework
        PYTHON_SLICE=""
        for slice_dir in "$PYTHON_XCFW"/*/; do
            slice_name=$(basename "$slice_dir")
            if [[ "$slice_name" == ios-arm64* ]] && [ -d "$slice_dir/Python.framework" ]; then
                PYTHON_SLICE="$slice_dir"
                break
            fi
        done
        if [ -n "$PYTHON_SLICE" ]; then
            cp -r "$PYTHON_SLICE/Python.framework" "$FRAMEWORKS_DIR/"
            echo "✅ Copied Python.framework from $(basename "$PYTHON_SLICE") slice to Frameworks/"
        else
            echo "❌ ERROR: No ios-arm64 slice with Python.framework found in xcframework"
            echo "   Run scripts/download-runtime.sh first."
            exit 1
        fi
    else
        echo "❌ ERROR: Python.xcframework not found at $PYTHON_XCFW"
        echo "   Run scripts/download-runtime.sh first."
        exit 1
    fi
else
    echo "✅ Python.framework already embedded by Xcode"
fi

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
# Covers both standalone binaries (node) and .framework bundles (libssh2, openssl, Python)
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

# 5b. Framework bundle binaries (e.g. libssh2.framework/libssh2, Python.framework/Python)
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

# 6. Install Python standard library to .app/python/
# This copies the Python stdlib from Python.xcframework into the app bundle
# so that PYTHONHOME can find it at runtime.
APP_BUNDLE="$OUTPUT_DIR/ipa/Payload/$PRODUCT_NAME.app"
PYTHON_XCFW_SRC="Baize/Baize/Frameworks/Python.xcframework"
if [ -d "$PYTHON_XCFW_SRC" ]; then
    echo ""
    echo "📦 Installing Python standard library..."
    if [ -f "$PYTHON_XCFW_SRC/build/build_utils.sh" ]; then
        # Use BeeWare's install_python script (preferred)
        source "$PYTHON_XCFW_SRC/build/build_utils.sh"
        install_python "$PYTHON_XCFW_SRC" "$APP_BUNDLE"
        echo "✅ install_python: Python stdlib installed to $APP_BUNDLE/python/"
    else
        # Fallback: manually copy stdlib from Python.framework
        echo "⚠️ build_utils.sh not found, manually copying Python stdlib..."
        PYTHON_VERSION_TAG="3.13"
        PYTHON_STDLIB_SRC=""
        for slice_dir in "$PYTHON_XCFW_SRC"/*/; do
            slice_name=$(basename "$slice_dir")
            if [[ "$slice_name" == ios-arm64* ]]; then
                stdlib_path="$slice_dir/Python.framework/Versions/Current/lib/python$PYTHON_VERSION_TAG"
                if [ -d "$stdlib_path" ]; then
                    PYTHON_STDLIB_SRC="$stdlib_path"
                    break
                fi
                # Also check without Versions/Current
                stdlib_path="$slice_dir/Python.framework/lib/python$PYTHON_VERSION_TAG"
                if [ -d "$stdlib_path" ]; then
                    PYTHON_STDLIB_SRC="$stdlib_path"
                    break
                fi
            fi
        done
        if [ -n "$PYTHON_STDLIB_SRC" ]; then
            mkdir -p "$APP_BUNDLE/python/lib"
            cp -r "$PYTHON_STDLIB_SRC" "$APP_BUNDLE/python/lib/"
            echo "✅ Manually copied Python stdlib (fallback) to $APP_BUNDLE/python/lib/"
        else
            echo "⚠️ WARNING: Could not find Python stdlib in xcframework"
            echo "   Python execution may fail at runtime (import errors)"
        fi
    fi
else
    echo "⚠️ WARNING: Python.xcframework not found at $PYTHON_XCFW_SRC"
    echo "   Python stdlib will not be installed. Run scripts/download-runtime.sh first."
fi

# 7. Verify bootstrap.py is in the app bundle
BOOTSTRAP_PY="$APP_BUNDLE/python_scripts/bootstrap.py"
if [ -f "$BOOTSTRAP_PY" ]; then
    echo "✅ bootstrap.py found in app bundle"
else
    echo "⚠️ WARNING: bootstrap.py not found at $BOOTSTRAP_PY"
    echo "   Python engine may fail to start. Check project.yml python_scripts resource."
fi

# 8. Create IPA
cd "$OUTPUT_DIR/ipa"
zip -r "$PRODUCT_NAME.ipa" Payload
cd -
mkdir -p "$OUTPUT_DIR"
mv "$OUTPUT_DIR/ipa/$PRODUCT_NAME.ipa" "$OUTPUT_DIR/"
rm -rf "$OUTPUT_DIR/ipa"

echo "✅ IPA created: $OUTPUT_DIR/$PRODUCT_NAME.ipa"
ls -lh "$OUTPUT_DIR/$PRODUCT_NAME.ipa"
