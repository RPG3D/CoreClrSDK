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
#   platform         Target platform: linux | macos | android | ios | iossimulator | iossimulatorx64
#   build-type       Debug (default) | Release
#
# Note: Windows uses CopySDKFromSrc.bat, not this script.
#
# iossimulator      = iOS Simulator arm64 (Apple Silicon host)  -> iossimulator/
# iossimulatorx64   = iOS Simulator x64   (Intel host)          -> iossimulatorx64/
# The iOS Simulator arch follows the host Mac CPU: arm64 on Apple Silicon,
# x64 on Intel. Build/pick the matching arch explicitly to avoid host-coupling.
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
    linux|macos|android|ios|iossimulator|iossimulatorx64) ;;
    *)
        echo "Error: unknown platform '$PLATFORM'." >&2
        exit 1
        ;;
esac

# ── Set platform-specific variables ──────────────────────────────────────────
SRC_ARTIFACTS="$DOTNET_SRC/artifacts"

case "$PLATFORM" in
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
    iossimulatorx64)
        CORECLR_TRIPLE="iossimulator.x64.$BUILD_TYPE"
        RUNTIME_RID="iossimulator-x64"
        DEST="$SDK_DIR/iossimulatorx64"
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

# 1a. CoreCLR runtime engines (from coreclr artifacts + runtime pack native)
# Unix platforms use "lib<name>.so/dylib"
for lib in coreclr clrjit clrinterpreter mscordaccore mscordbi; do
    copied=false
    # Try CORECLR_DIR first
    if [[ -d "$CORECLR_DIR" ]]; then
        for ext in so dylib; do
            src="$CORECLR_DIR/lib${lib}.${ext}"
            if [[ -f "$src" ]]; then
                cp "$src" "$DEST/lib/"
                echo "  lib${lib}.${ext}"
                copied=true
                break
            fi
        done
    fi
    # Fallback: check runtime pack native
    if [[ "$copied" != "true" && -d "$RUNTIME_PACK_NATIVE" ]]; then
        for ext in so dylib; do
            src="$RUNTIME_PACK_NATIVE/lib${lib}.${ext}"
            if [[ -f "$src" ]]; then
                cp "$src" "$DEST/lib/"
                echo "  lib${lib}.${ext}"
                copied=true
                break
            fi
        done
    fi
done

# 1b. System native shims (from runtime pack native)
# Unix: lib<name>.so/dylib
if [[ -d "$RUNTIME_PACK_NATIVE" ]]; then
    for lib in System.Native System.IO.Compression.Native System.Globalization.Native System.Net.Security.Native; do
        for ext in so dylib; do
            src="$RUNTIME_PACK_NATIVE/lib${lib}.${ext}"
            if [[ -f "$src" ]]; then
                cp "$src" "$DEST/lib/"
                echo "  lib${lib}.${ext}"
                break
            fi
        done
    done
    # Platform-specific crypto shim
    for lib in System.Security.Cryptography.Native.Apple System.Security.Cryptography.Native.Android System.Security.Cryptography.Native.OpenSsl; do
        for ext in so dylib; do
            src="$RUNTIME_PACK_NATIVE/lib${lib}.${ext}"
            if [[ -f "$src" ]]; then
                cp "$src" "$DEST/lib/"
                echo "  lib${lib}.${ext}"
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
# Falls back to runtime-pack-native copy when CoreLib is missing from managed dir
# (.NET 10 Windows puts ReadyToRun CoreLib in native/, not managed lib/net10.0)
CORECLR_IL_DIR="$CORECLR_DIR/IL"
SPC_DEST="$DEST/runtime/System.Private.CoreLib.dll"
SPC_PDB_DEST="$DEST/runtime/System.Private.CoreLib.pdb"

if [[ -f "$CORECLR_IL_DIR/System.Private.CoreLib.dll" ]]; then
    cp "$CORECLR_IL_DIR/System.Private.CoreLib.dll" "$SPC_DEST"
    echo "  System.Private.CoreLib.dll (pure-IL from CoreCLR IL/)"
    if [[ -f "$CORECLR_IL_DIR/System.Private.CoreLib.pdb" ]]; then
        cp "$CORECLR_IL_DIR/System.Private.CoreLib.pdb" "$SPC_PDB_DEST"
        echo "  System.Private.CoreLib.pdb (from CoreCLR IL/)"
    fi
elif [[ ! -f "$SPC_DEST" && -f "$RUNTIME_PACK_NATIVE/System.Private.CoreLib.dll" ]]; then
    cp "$RUNTIME_PACK_NATIVE/System.Private.CoreLib.dll" "$SPC_DEST"
    echo "  System.Private.CoreLib.dll (from runtime pack native — .NET 10 ReadyToRun)"
    if [[ -f "$RUNTIME_PACK_NATIVE/System.Private.CoreLib.pdb" ]]; then
        cp "$RUNTIME_PACK_NATIVE/System.Private.CoreLib.pdb" "$SPC_PDB_DEST"
        echo "  System.Private.CoreLib.pdb (from runtime pack native)"
    fi
fi

DLL_COUNT=$(find "$DEST/runtime" -maxdepth 1 -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
PDB_COUNT=$(find "$DEST/runtime" -maxdepth 1 -name "*.pdb" 2>/dev/null | wc -l | tr -d ' ')
echo "  Total: ${DLL_COUNT} DLLs + ${PDB_COUNT} PDBs"

# ── 4. Write VERSION.txt (matching MonoSDK convention) ─────────────────────────
DOTNET_BRANCH="$(cd "$DOTNET_SRC" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
DOTNET_COMMIT="$(cd "$DOTNET_SRC" && git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

cat > "$DEST/VERSION.txt" <<EOF
dotnet/runtime source
  repo:   $(cd "$DOTNET_SRC" && git remote get-url origin 2>/dev/null || echo 'unknown')
  branch: $DOTNET_BRANCH
  commit: $DOTNET_COMMIT

Platform: $PLATFORM
Build type: $BUILD_TYPE
Build subsets: clr.runtime+clr.alljits+clr.corelib+clr.nativecorelib+clr.tools+clr.packages+libs
EOF

# ── 3. iOS-specific: build .embeddedframework.zip ───────────────────────────
case "$PLATFORM" in
    ios|iossimulator|iossimulatorx64)
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
