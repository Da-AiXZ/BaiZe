#!/bin/bash
set -euo pipefail

# download-runtime.sh — 下载/创建 Runtime 二进制
# Node.js: nodejs-mobile NodeMobile.framework v18.20.4 (real)
# Python: BeeWare Python-Apple-support 3.13-b14 (CPython iOS embed)

RUNTIME_DIR="Baize/Baize/Frameworks"
mkdir -p "$RUNTIME_DIR"

echo "📥 Preparing runtime binaries..."

# ============================================
# Node.js Runtime (nodejs-mobile NodeMobile.framework v18.20.4)
# ============================================
NODEMOBILE_FRAMEWORK="$RUNTIME_DIR/NodeMobile.framework"
if [ -d "$NODEMOBILE_FRAMEWORK" ]; then
    echo "✅ NodeMobile.framework already exists"
else
    echo "📥 Downloading nodejs-mobile v18.20.4 iOS..."
    NODE_URL="https://github.com/nodejs-mobile/nodejs-mobile/releases/download/v18.20.4/nodejs-mobile-v18.20.4-ios.zip"
    curl -fL --retry 3 --retry-delay 5 -o /tmp/nodejs-mobile-ios.zip "$NODE_URL"

    # Verify download
    ZIP_SIZE=$(stat -f%z /tmp/nodejs-mobile-ios.zip 2>/dev/null || stat -c%s /tmp/nodejs-mobile-ios.zip 2>/dev/null || echo 0)
    if [ "$ZIP_SIZE" -lt 1000000 ]; then
        echo "❌ ERROR: Downloaded file is only $ZIP_SIZE bytes (expected ~51MB)"
        rm -f /tmp/nodejs-mobile-ios.zip
        exit 1
    fi
    echo "   Downloaded $(( ZIP_SIZE / 1024 )) KB"

    echo "📂 Unzipping nodejs-mobile..."
    unzip -q -o /tmp/nodejs-mobile-ios.zip -d /tmp/nodejs-mobile

    # Extract device-only framework (arm64)
    # Actual zip structure: NodeMobile.xcframework/ios-arm64/NodeMobile.framework/
    if [ -d "/tmp/nodejs-mobile/NodeMobile.xcframework/ios-arm64/NodeMobile.framework" ]; then
        cp -r /tmp/nodejs-mobile/NodeMobile.xcframework/ios-arm64/NodeMobile.framework "$RUNTIME_DIR/"
        echo "✅ NodeMobile.framework (arm64 device) extracted from xcframework"
    elif [ -d "/tmp/nodejs-mobile/Release-iphoneos/NodeMobile.framework" ]; then
        cp -r /tmp/nodejs-mobile/Release-iphoneos/NodeMobile.framework "$RUNTIME_DIR/"
        echo "✅ NodeMobile.framework (arm64 device) extracted from Release-iphoneos"
    else
        echo "❌ ERROR: NodeMobile.framework not found in zip"
        echo "   Available top-level directories:"
        ls -1 /tmp/nodejs-mobile/ 2>/dev/null || true
        echo "   Searching for NodeMobile.framework anywhere in zip..."
        find /tmp/nodejs-mobile -name "NodeMobile.framework" -type d 2>/dev/null || true
        rm -f /tmp/nodejs-mobile-ios.zip
        rm -rf /tmp/nodejs-mobile
        exit 1
    fi

    # Verify framework structure
    if [ ! -f "$NODEMOBILE_FRAMEWORK/NodeMobile" ]; then
        echo "❌ ERROR: NodeMobile binary not found in framework bundle"
        exit 1
    fi
    if [ ! -f "$NODEMOBILE_FRAMEWORK/Headers/NodeMobile.h" ]; then
        echo "⚠️ WARNING: Headers/NodeMobile.h not found in framework"
        echo "   Bridging Header import may fail. Check framework structure:"
        find "$NODEMOBILE_FRAMEWORK" -type f || true
    fi

    # Clean up
    rm -f /tmp/nodejs-mobile-ios.zip
    rm -rf /tmp/nodejs-mobile

    echo "✅ NodeMobile.framework installed to $RUNTIME_DIR/"
fi

# ============================================
# Python Runtime (BeeWare Python-Apple-support 3.13-b14)
# ============================================
PYTHON_XCFRAMEWORK="$RUNTIME_DIR/Python.xcframework"
if [ -d "$PYTHON_XCFRAMEWORK" ]; then
    echo "✅ Python.xcframework already exists"
else
    echo "📥 Downloading BeeWare Python 3.13-b14 iOS support..."
    PYTHON_URL="https://github.com/beeware/Python-Apple-support/releases/download/3.13-b14/Python-3.13-iOS-support.b14.tar.gz"
    curl -fL --retry 3 --retry-delay 5 -o /tmp/python-ios.tar.gz "$PYTHON_URL"

    # Verify download
    TAR_SIZE=$(stat -f%z /tmp/python-ios.tar.gz 2>/dev/null || stat -c%s /tmp/python-ios.tar.gz 2>/dev/null || echo 0)
    if [ "$TAR_SIZE" -lt 5000000 ]; then
        echo "❌ ERROR: Downloaded file is only $TAR_SIZE bytes (expected ~31MB)"
        rm -f /tmp/python-ios.tar.gz
        exit 1
    fi
    echo "   Downloaded $(( TAR_SIZE / 1024 )) KB"

    echo "📂 Extracting BeeWare Python..."
    mkdir -p /tmp/python-ios
    tar -xzf /tmp/python-ios.tar.gz -C /tmp/python-ios

    # Find Python.xcframework in extracted contents
    EXTRACTED_XCFW=$(find /tmp/python-ios -maxdepth 1 -type d -name "Python.xcframework" | head -n 1)
    if [ -n "$EXTRACTED_XCFW" ]; then
        cp -r "$EXTRACTED_XCFW" "$RUNTIME_DIR/"
        echo "✅ Python.xcframework extracted to $RUNTIME_DIR/"
    else
        echo "❌ ERROR: Python.xcframework not found in tarball"
        echo "   Contents of extracted directory:"
        ls -1 /tmp/python-ios/ 2>/dev/null || true
        echo "   Searching for Python.xcframework anywhere..."
        find /tmp/python-ios -name "Python.xcframework" -type d 2>/dev/null || true
        rm -f /tmp/python-ios.tar.gz
        rm -rf /tmp/python-ios
        exit 1
    fi

    # Verify xcframework structure
    if [ ! -d "$PYTHON_XCFRAMEWORK" ]; then
        echo "❌ ERROR: Python.xcframework not properly copied"
        rm -f /tmp/python-ios.tar.gz
        rm -rf /tmp/python-ios
        exit 1
    fi

    # Verify Headers/Python.h exists (needed for Bridging Header)
    PYTHON_H_FOUND=""
    for slice_dir in "$PYTHON_XCFRAMEWORK"/*/; do
        if [ -f "$slice_dir/Python.framework/Headers/Python.h" ]; then
            PYTHON_H_FOUND="$slice_dir/Python.framework/Headers/Python.h"
            break
        fi
    done
    if [ -n "$PYTHON_H_FOUND" ]; then
        echo "✅ Python.h found: $PYTHON_H_FOUND"
    else
        echo "⚠️ WARNING: Python.h not found in any slice of Python.xcframework"
        echo "   Bridging Header import may fail. Check xcframework structure:"
        find "$PYTHON_XCFRAMEWORK" -name "Python.h" 2>/dev/null || true
    fi

    # Verify build_utils.sh exists (needed for install_python Build Phase)
    BUILD_UTILS="$PYTHON_XCFRAMEWORK/build/build_utils.sh"
    if [ -f "$BUILD_UTILS" ]; then
        echo "✅ build_utils.sh found (install_python available)"
    else
        echo "⚠️ WARNING: build_utils.sh not found at $BUILD_UTILS"
        echo "   install_python Build Phase will use fallback stdlib copy"
    fi

    # Clean up
    rm -f /tmp/python-ios.tar.gz
    rm -rf /tmp/python-ios

    echo "✅ Python.xcframework installed to $RUNTIME_DIR/"
fi

# ============================================
# Verify
# ============================================
echo ""
echo "=== Runtime Binaries ==="
ls -la "$RUNTIME_DIR/"
if [ -d "$RUNTIME_DIR/NodeMobile.framework" ]; then
    echo ""
    echo "=== NodeMobile.framework ==="
    ls -la "$RUNTIME_DIR/NodeMobile.framework/"
fi
if [ -d "$RUNTIME_DIR/Python.xcframework" ]; then
    echo ""
    echo "=== Python.xcframework ==="
    ls -la "$RUNTIME_DIR/Python.xcframework/"
    echo ""
    echo "=== Python.xcframework slices ==="
    ls -1 "$RUNTIME_DIR/Python.xcframework/" | grep -v "\.txt\|build" || true
fi

echo ""
echo "✅ Node.js: NodeMobile.framework (nodejs-mobile v18.20.4, arm64 device)"
echo "✅ Python: Python.xcframework (BeeWare Python 3.13-b14, CPython iOS embed)"
