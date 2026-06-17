#!/bin/bash
set -euo pipefail

# verify-ipa.sh — 验证 IPA 结构和内容
# Usage: verify-ipa.sh <ipa-path>

IPA_PATH="${1:?Usage: verify-ipa.sh <ipa-path>}"
PRODUCT_NAME="Baize"

echo "🔍 Verifying IPA: $IPA_PATH"
echo ""

if [ ! -f "$IPA_PATH" ]; then
    echo "❌ IPA file not found: $IPA_PATH"
    exit 1
fi

# 1. Unzip for inspection
VERIFY_DIR="/tmp/baize-ipa-verify-$$"
rm -rf "$VERIFY_DIR"
mkdir -p "$VERIFY_DIR"
unzip -q "$IPA_PATH" -d "$VERIFY_DIR"

PASS=0
FAIL=0

# 2. Check bundle structure
echo "=== Bundle Structure ==="
APP_DIR="$VERIFY_DIR/Payload/$PRODUCT_NAME.app"
if [ -d "$APP_DIR" ]; then
    echo "✅ Payload/$PRODUCT_NAME.app exists"
    ((PASS++))
else
    echo "❌ Payload/$PRODUCT_NAME.app NOT found"
    ((FAIL++))
fi

# 3. Check main executable
echo ""
echo "=== Main Executable ==="
EXECUTABLE="$APP_DIR/$PRODUCT_NAME"
if [ -f "$EXECUTABLE" ]; then
    echo "✅ Main executable exists: $PRODUCT_NAME"
    ((PASS++))
    if [ -x "$EXECUTABLE" ]; then
        echo "✅ Main executable is executable"
        ((PASS++))
    else
        echo "❌ Main executable is NOT executable"
        ((FAIL++))
    fi
else
    echo "❌ Main executable NOT found"
    ((FAIL++))
fi

# 4. Check entitlements
echo ""
echo "=== Entitlements ==="
if [ -f "$EXECUTABLE" ]; then
    ENTITLEMENTS_OUTPUT=$(ldid -e "$EXECUTABLE" 2>/dev/null || true)
    if echo "$ENTITLEMENTS_OUTPUT" | grep -q "no-sandbox"; then
        echo "✅ Entitlement 'no-sandbox' found"
        ((PASS++))
    else
        echo "⚠️ Entitlement 'no-sandbox' not found (may be embedded differently)"
    fi
    if echo "$ENTITLEMENTS_OUTPUT" | grep -q "platform-application"; then
        echo "✅ Entitlement 'platform-application' found"
        ((PASS++))
    else
        echo "⚠️ Entitlement 'platform-application' not found"
    fi
fi

# 5. Check Info.plist
echo ""
echo "=== Info.plist ==="
INFO_PLIST="$APP_DIR/Info.plist"
if [ -f "$INFO_PLIST" ]; then
    echo "✅ Info.plist exists"
    ((PASS++))
    # Check CFBundleIdentifier
    BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST" 2>/dev/null || true)
    if [ "$BUNDLE_ID" = "com.baize.app" ]; then
        echo "✅ CFBundleIdentifier = com.baize.app"
        ((PASS++))
    else
        echo "⚠️ CFBundleIdentifier = $BUNDLE_ID (expected com.baize.app)"
    fi
else
    echo "❌ Info.plist NOT found"
    ((FAIL++))
fi

# 6. Check Frameworks (runtime binaries)
echo ""
echo "=== Frameworks (Runtime Binaries) ==="
FRAMEWORKS_DIR="$APP_DIR/Frameworks"
if [ -d "$FRAMEWORKS_DIR" ]; then
    echo "✅ Frameworks/ directory exists"
    ((PASS++))
    for binary in node python3; do
        if [ -f "$FRAMEWORKS_DIR/$binary" ]; then
            echo "✅ $binary found in Frameworks/"
            ((PASS++))
        else
            echo "⚠️ $binary NOT found in Frameworks/ (placeholder may not be embedded)"
        fi
    done

    # Check ios_system runtime dependencies (libssh2, openssl)
    # Required by curl_ios.framework and ssh_cmd.framework at runtime
    echo ""
    echo "--- ios_system Runtime Dependencies ---"
    for fw_name in libssh2 openssl; do
        fw_path="$FRAMEWORKS_DIR/$fw_name.framework"
        if [ -d "$fw_path" ]; then
            echo "✅ $fw_name.framework found in Frameworks/"
            ((PASS++))
            # Verify the framework binary exists and is a Mach-O
            fw_binary="$fw_path/$fw_name"
            if [ -f "$fw_binary" ]; then
                if file "$fw_binary" | grep -q "Mach-O"; then
                    echo "✅ $fw_name.framework/$fw_name is a valid Mach-O"
                    ((PASS++))
                else
                    echo "❌ $fw_name.framework/$fw_name is NOT a Mach-O binary"
                    ((FAIL++))
                fi
            else
                echo "❌ $fw_name.framework/$fw_name binary NOT found"
                ((FAIL++))
            fi
        else
            echo "❌ $fw_name.framework NOT found in Frameworks/ (DYLD crash expected)"
            ((FAIL++))
        fi
    done
else
    echo "⚠️ Frameworks/ directory NOT found (runtime binaries not embedded)"
fi

# 7. Check monaco-editor
echo ""
echo "=== Monaco Editor Resources ==="
MONACO_DIR="$APP_DIR/monaco-editor"
if [ -d "$MONACO_DIR" ]; then
    echo "✅ monaco-editor/ directory exists in app bundle"
    ((PASS++))

    # Check index.html
    if [ -f "$MONACO_DIR/index.html" ]; then
        echo "✅ monaco-editor/index.html exists"
        ((PASS++))
    else
        echo "❌ monaco-editor/index.html NOT found"
        ((FAIL++))
    fi

    # Check min/vs directory (Monaco editor core)
    if [ -d "$MONACO_DIR/min/vs" ]; then
        echo "✅ monaco-editor/min/vs/ directory exists (Monaco core)"
        ((PASS++))

        # Check loader.js
        if [ -f "$MONACO_DIR/min/vs/loader.js" ]; then
            echo "✅ monaco-editor/min/vs/loader.js exists"
            ((PASS++))
        else
            echo "❌ monaco-editor/min/vs/loader.js NOT found"
            ((FAIL++))
        fi

        # Report Monaco resource size
        MONACO_SIZE=$(du -sh "$MONACO_DIR/min/" 2>/dev/null | awk '{print $1}' || echo "unknown")
        MONACO_FILES=$(find "$MONACO_DIR/min/" -type f 2>/dev/null | wc -l | tr -d ' ')
        echo "   Monaco min/ size: ${MONACO_SIZE} (${MONACO_FILES} files)"
    else
        echo "⚠️ monaco-editor/min/vs/ NOT found (Monaco core not downloaded)"
    fi
else
    echo "⚠️ monaco-editor/ directory NOT found"
fi

# 8. Summary
echo ""
echo "======================================"
echo "Verification Summary: $PASS passed, $FAIL failed"
echo "======================================"

# Cleanup
rm -rf "$VERIFY_DIR"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
