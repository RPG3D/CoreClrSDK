#!/usr/bin/env bash
# CopySDKFromSrc.sh — copy CoreCLR artifacts from dotnet/runtime build output
# into the CoreClrSDK platform subdirectory.
#
# This script does NOT build dotnet/runtime — it only copies pre-built artifacts.
# Use BuildCoreClrSDK.sh first to build, then this script to copy.
#
# Usage:
#   ./CopySDKFromSrc.sh <dotnet-src-dir> <platform> [build-type]
#
# Arguments:
#   dotnet-src-dir   Path to the dotnet/runtime repository root (must be already built).
#   platform         Target platform: win64 | linux | macos | android | ios | iossimulator
#   build-type       Debug (default) | Release
#
# Reference: MonoSDK/CopySDKFromSrc.sh (same approach: cp -Rf directories, no manual file listing)

set -euo pipefail

# ── Arguments ─────────────────────────────────────────────────────────────────
DOTNET_SRC="${1:-}"
PLATFORM="${2:-}"
if [[ -z "$DOTNET_SRC" || -z "$PLATFORM" ]]; then
    echo "Error: missing required arguments." >&2
    echo "Usage: $0 <dotnet-src-dir> <platform> [build-type]" >&2
    exit 1
fi
DOTNET_SRC="$(cd "$DOTNET_SRC" && pwd)"

BUILD_TYPE_RAW="${3:-Debug}"
BUILD_TYPE_LOWER="$(echo "$BUILD_TYPE_RAW" | tr '[:upper:]' '[:lower:]')"
case "$BUILD_TYPE_LOWER" in
    debug)   BUILD_TYPE="Debug" ;;
    release) BUILD_TYPE="Release" ;;
    *)
        echo "Error: unknown build-type '${BUILD_TYPE_RAW}'. Use Debug or Release." >&2
        exit 1
        ;;
esac

SDK_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== CopySDKFromSrc ==="
echo "  Source    : $DOTNET_SRC"
echo "  Platform  : $PLATFORM"
echo "  Build type: $BUILD_TYPE"
echo "  SDK dir   : $SDK_DIR"
echo ""

# ── Validate platform ────────────────────────────────────────────────────────
case "$PLATFORM" in
    win64|linux|macos|android|ios|iossimulator) ;;
    *)
        echo "Error: unknown platform '$PLATFORM'." >&2
        exit 1
        ;;
esac

# ── Set platform-specific variables ──────────────────────────────────────────
SRC_ARTIFACTS="$DOTNET_SRC/artifacts"

case "$PLATFORM" in
    win64)
        CORECLR_TRIPLE="win.x64.$BUILD_TYPE"
        RUNTIME_RID="win-x64"
        DEST="$SDK_DIR/win64"
        ;;
    linux)
        CORECLR_TRIPLE="linux.x64.$BUILD_TYPE"
        RUNTIME_RID="linux-x64"
        DEST="$SDK_DIR/linux"
        ;;
    macos)
        CORECLR_TRIPLE="osx.arm64.$BUILD_TYPE"
        RUNTIME_RID="osx-arm64"
        DEST="$SDK_DIR/macos"
        ;;
    android)
        CORECLR_TRIPLE="android.arm64.$BUILD_TYPE"
        RUNTIME_RID="android-arm64"
        DEST="$SDK_DIR/android"
        ;;
    ios)
        CORECLR_TRIPLE="ios.arm64.$BUILD_TYPE"
        RUNTIME_RID="ios-arm64"
        DEST="$SDK_DIR/ios"
        ;;
    iossimulator)
        CORECLR_TRIPLE="iossimulator.arm64.$BUILD_TYPE"
        RUNTIME_RID="iossimulator-arm64"
        DEST="$SDK_DIR/iossimulator"
        ;;
esac

CORECLR_DIR="$SRC_ARTIFACTS/bin/coreclr/$CORECLR_TRIPLE"
RUNTIME_PACK="$SRC_ARTIFACTS/bin/microsoft.netcore.app.runtime.$RUNTIME_RID/$BUILD_TYPE/runtimes/$RUNTIME_RID"
RUNTIME_PACK_NATIVE="$RUNTIME_PACK/native"
RUNTIME_PACK_MANAGED="$RUNTIME_PACK/lib/net10.0"

echo ">>> Copying artifacts into SDK directory..."
rm -rf "$DEST"
mkdir -p "$DEST/lib" "$DEST/runtime"

# ── 1. Native libraries → <platform>/lib/ ───────────────────────────────────
echo "--- Native libraries ---"

# 1a. CoreCLR runtime engines (from coreclr artifacts)
# Only copy the base libs (skip cross-compiled JIT variants)
if [[ -d "$CORECLR_DIR" ]]; then
    for lib in libcoreclr libclrjit libclrinterpreter; do
        for ext in so dylib dll; do
            src="$CORECLR_DIR/${lib}.${ext}"
            if [[ -f "$src" ]]; then
                cp "$src" "$DEST/lib/"
                echo "  ${lib}.${ext}"
                break
            fi
        done
    done
fi

# 1b. System native shims (from runtime pack native)
if [[ -d "$RUNTIME_PACK_NATIVE" ]]; then
    for lib in libSystem.Native libSystem.IO.Compression.Native libSystem.Globalization.Native libSystem.Net.Security.Native; do
        for ext in so dylib dll; do
            src="$RUNTIME_PACK_NATIVE/${lib}.${ext}"
            if [[ -f "$src" ]]; then
                cp "$src" "$DEST/lib/"
                echo "  ${lib}.${ext}"
                break
            fi
        done
    done
    # Platform-specific crypto shim
    for lib in libSystem.Security.Cryptography.Native.Apple libSystem.Security.Cryptography.Native.Android; do
        for ext in so dylib dll; do
            src="$RUNTIME_PACK_NATIVE/${lib}.${ext}"
            if [[ -f "$src" ]]; then
                cp "$src" "$DEST/lib/"
                echo "  ${lib}.${ext}"
                break
            fi
        done
    done
fi

NATIVE_COUNT=$(find "$DEST/lib" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
echo "  Total: ${NATIVE_COUNT} native files"

# ── 2. BCL managed DLLs + PDBs → <platform>/runtime/ ───────────────────────
# MonoSDK approach: cp -Rf the entire managed directory
# (catches .dll + .pdb + .json together, no manual file listing)
echo ""
echo "--- BCL managed DLLs + PDBs ---"

if [[ -d "$RUNTIME_PACK_MANAGED" ]]; then
    cd "$RUNTIME_PACK_MANAGED"
    cp -Rf . "$DEST/runtime/" 2>/dev/null || true
    cd "$SDK_DIR"
else
    echo "  ERROR: Runtime pack managed DLLs not found at $RUNTIME_PACK_MANAGED"
    exit 1
fi

# 2a. Overwrite System.Private.CoreLib.dll with pure-IL version (iOS interpreter fix)
CORECLR_IL="$CORECLR_DIR/IL/System.Private.CoreLib.dll"
CORECLR_PDB="$CORECLR_DIR/IL/System.Private.CoreLib.pdb"
if [[ -f "$CORECLR_IL" ]]; then
    cp "$CORECLR_IL" "$DEST/runtime/System.Private.CoreLib.dll"
    echo "  System.Private.CoreLib.dll (pure-IL from CoreCLR IL/)"
    if [[ -f "$CORECLR_PDB" ]]; then
        cp "$CORECLR_PDB" "$DEST/runtime/System.Private.CoreLib.pdb"
        echo "  System.Private.CoreLib.pdb (from CoreCLR IL/)"
    fi
fi

DLL_COUNT=$(find "$DEST/runtime" -maxdepth 1 -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
PDB_COUNT=$(find "$DEST/runtime" -maxdepth 1 -name "*.pdb" 2>/dev/null | wc -l | tr -d ' ')
echo "  Total: ${DLL_COUNT} DLLs + ${PDB_COUNT} PDBs"

# ── 3. iOS-specific: build .embeddedframework.zip ───────────────────────────
case "$PLATFORM" in
    ios|iossimulator)
        echo ""
        echo "--- iOS .embeddedframework.zip ---"
        bash "$SDK_DIR/MakeCoreClrFramework.sh" "$PLATFORM" "$DEST/lib" "$DEST/lib"
        ;;
esac

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Done. CoreClrSDK populated for $PLATFORM ($BUILD_TYPE). ==="
echo "  Native:  $DEST/lib/ ($(find "$DEST/lib" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ') files)"
echo "  Managed: $DEST/runtime/ (${DLL_COUNT} DLLs + ${PDB_COUNT} PDBs)"
