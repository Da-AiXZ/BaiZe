#!/bin/bash
set -euo pipefail

# download-runtime.sh — 下载/创建 Runtime 二进制
# Phase 2B: placeholder scripts
# Phase 2D: 真实 nodejs-mobile + CPython iOS binary

RUNTIME_DIR="Baize/Baize/Frameworks"
mkdir -p "$RUNTIME_DIR"

echo "📥 Preparing runtime binaries..."

# ============================================
# Node.js Runtime (nodejs-mobile --jitless)
# ============================================
if [ -f "$RUNTIME_DIR/node" ]; then
    echo "✅ Node.js binary already exists"
else
    echo "Creating Node.js placeholder binary (Phase 2B)..."
    cat > "$RUNTIME_DIR/node" << 'NODEEOF'
#!/bin/sh
# Node.js placeholder - Phase 2B
# Phase 2D: Replace with real nodejs-mobile arm64 binary
echo "Node.js placeholder - Phase 2B"
echo "This binary will be replaced with nodejs-mobile arm64 in Phase 2D"
exit 0
NODEEOF
    chmod +x "$RUNTIME_DIR/node"
    echo "✅ Node.js placeholder binary created"
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

echo ""
echo "⚠️ Note: These are placeholder binaries for Phase 2B."
echo "   Phase 2D will replace them with real nodejs-mobile + CPython iOS binaries."
