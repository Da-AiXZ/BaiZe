#!/bin/bash
set -euo pipefail

# patch-xcframeworks.sh — Patch ios_system xcframeworks to lower MinimumOSVersion
# from 17.5 to 16.0, preventing Xcode 15+ from auto-raising IPHONEOS_DEPLOYMENT_TARGET.
#
# Root cause: ios_system v3.0.4 xcframeworks declare MinimumOSVersion=17.5 in their
# Info.plist and LC_BUILD_VERSION load command. Xcode 15+ reads this metadata and
# auto-raises the project's deployment target from 16.0 to 17.5, causing the compiled
# binary to reference iOS 17 SwiftUI symbols (e.g. StrokeShapeView) that don't exist
# on iOS 16.6, resulting in a dyld SIGABRT crash on launch.
#
# Fix: Patch both the xcframework Info.plist AND the Mach-O binary's LC_BUILD_VERSION
# to declare MinimumOSVersion=16.0, so Xcode keeps the deployment target at 16.0.
#
# Usage: patch-xcframeworks.sh <SourcePackages-dir>

SOURCE_PACKAGES="${1:?Usage: patch-xcframeworks.sh <SourcePackages-dir>}"
ARTIFACTS_DIR="$SOURCE_PACKAGES/artifacts"

if [ ! -d "$ARTIFACTS_DIR" ]; then
    echo "⚠️  Artifacts directory not found at $ARTIFACTS_DIR"
    echo "    Skipping xcframework patching (SPM may not have resolved yet)."
    exit 0
fi

echo "🔧 Patching ios_system xcframeworks: MinimumOSVersion 17.5 → 16.0"
echo "   Scanning: $ARTIFACTS_DIR"
echo ""

PATCHED_PLISTS=0
PATCHED_BINARIES=0
SKIPPED=0

for xcframework_dir in "$ARTIFACTS_DIR"/*/*.xcframework; do
    [ -d "$xcframework_dir" ] || continue

    xcframework_name=$(basename "$xcframework_dir" .xcframework)

    # --- 1. Patch xcframework Info.plist MinimumOSVersion ---
    info_plist="$xcframework_dir/Info.plist"
    if [ -f "$info_plist" ]; then
        # Use PlistBuddy to iterate over AvailableLibraries array entries
        idx=0
        while /usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$idx:MinimumOSVersion" "$info_plist" 2>/dev/null; do
            current_min=$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$idx:MinimumOSVersion" "$info_plist" 2>/dev/null || echo "?")
            slice_id=$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$idx:LibraryIdentifier" "$info_plist" 2>/dev/null || echo "?")

            if [ "$current_min" != "16.0" ]; then
                /usr/libexec/PlistBuddy -c "Set :AvailableLibraries:$idx:MinimumOSVersion 16.0" "$info_plist" 2>/dev/null
                echo "  📝 $xcframework_name [$slice_id]: Info.plist MinimumOSVersion $current_min → 16.0"
                ((PATCHED_PLISTS++))
            else
                echo "  ✅ $xcframework_name [$slice_id]: already 16.0 (skip)"
            fi
            ((idx++))
        done
    fi

    # --- 2. Patch Mach-O binaries' LC_BUILD_VERSION using vtool ---
    for slice_dir in "$xcframework_dir"/ios-*; do
        [ -d "$slice_dir" ] || continue
        slice_name=$(basename "$slice_dir")

        # Find .framework directories inside this slice
        for fw_dir in "$slice_dir"/*.framework; do
            [ -d "$fw_dir" ] || continue
            fw_name=$(basename "$fw_dir" .framework)
            binary="$fw_dir/$fw_name"

            if [ ! -f "$binary" ]; then
                continue
            fi
            if ! file "$binary" | grep -q "Mach-O"; then
                continue
            fi

            # Check current minos
            current_minos=$(vtool -show-build "$binary" 2>/dev/null | grep "minos" | head -1 | sed 's/.*minos //' || echo "unknown")

            if [ "$current_minos" = "16.0" ]; then
                echo "  ✅ $xcframework_name [$slice_name]: binary already minos=16.0 (skip)"
                ((SKIPPED++))
                continue
            fi

            # Patch: set platform=iphoneos, minos=16.0, sdk=17.5
            # SDK stays at 17.5 (the SDK it was actually built with — accurate metadata)
            if vtool -set-build-version iphoneos 16.0 17.5 -replace -output "$binary.tmp" "$binary" 2>/dev/null; then
                mv "$binary.tmp" "$binary"
                echo "  🔧 $xcframework_name [$slice_name]: binary minos $current_minos → 16.0"
                ((PATCHED_BINARIES++))
            else
                echo "  ⚠️  $xcframework_name [$slice_name]: vtool patch failed (no LC_BUILD_VERSION?)"
            fi
        done
    done

    echo ""
done

echo "========================================="
echo "✅ Patched $PATCHED_PLISTS Info.plist entries"
echo "✅ Patched $PATCHED_BINARIES Mach-O binaries"
echo "📊 Skipped (already 16.0): $SKIPPED"
echo "========================================="
