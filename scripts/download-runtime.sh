#!/bin/bash
set -euo pipefail

# download-runtime.sh — 下载/创建 Runtime 二进制
# Node.js: nodejs-mobile NodeMobile.framework v18.20.4 (real)
# Python: placeholder binary (future CPython iOS integration)

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
# Python Runtime (CPython iOS embed)
# ============================================
if [ -f "$RUNTIME_DIR/python3" ]; then
    echo "✅ Python binary already exists"
else
    echo "Creating Python placeholder binary (Phase 2B)..."
    cat > "$RUNTIME_DIR/python3" << 'PYEOF'
#!/bin/sh
# Python placeholder - Phase 2B
# Phase 2D: Replace with real CPython iOS arm64 binary
echo "Python placeholder - Phase 2B"
echo "This binary will be replaced with CPython iOS arm64 in Phase 2D"
exit 0
PYEOF
    chmod +x "$RUNTIME_DIR/python3"
    echo "✅ Python placeholder binary created"
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

echo ""
echo "✅ Node.js: NodeMobile.framework (nodejs-mobile v18.20.4, arm64 device)"
echo "⚠️ Python: placeholder binary (CPython iOS integration in future phase)"
