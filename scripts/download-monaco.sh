#!/bin/bash
set -euo pipefail

# download-monaco.sh — 下载 Monaco Editor npm 包并解压到 Resources 目录
# 在 CI 构建时由 build.yml 调用
# 也可在本地运行：bash scripts/download-monaco.sh

MONACO_VERSION="0.52.2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MONACO_DIR="$PROJECT_ROOT/Baize/Baize/Resources/monaco-editor"

echo "📦 Downloading Monaco Editor v${MONACO_VERSION}..."

# Create temp directory
TMPDIR=$(mktemp -d)
cd "$TMPDIR"

# Download monaco-editor npm package
npm pack "monaco-editor@${MONACO_VERSION}" 2>/dev/null
tar xzf monaco-editor-*.tgz

# Copy min directory (the actual editor)
mkdir -p "${MONACO_DIR}/min"
cp -r package/min/. "${MONACO_DIR}/min/"

# Ensure existing index.html is preserved (will be updated separately by task 2D-2)
# Only create index.html if it doesn't already exist
if [ ! -f "${MONACO_DIR}/index.html" ]; then
    echo "⚠️ index.html not found in ${MONACO_DIR}, will need to be created separately"
fi

# Cleanup
cd "$PROJECT_ROOT"
rm -rf "$TMPDIR"

echo "✅ Monaco Editor v${MONACO_VERSION} downloaded to ${MONACO_DIR}/min/"
echo ""
echo "=== Monaco Resources ==="
ls -la "${MONACO_DIR}/"
echo ""
echo "=== Monaco min/ ==="
ls "${MONACO_DIR}/min/" | head -20
echo ""
MONACO_SIZE=$(du -sh "${MONACO_DIR}/min/" 2>/dev/null | awk '{print $1}' || echo "unknown")
echo "Monaco min/ size: ${MONACO_SIZE}"
