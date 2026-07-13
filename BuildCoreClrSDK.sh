#!/usr/bin/env bash
# BuildCoreClrSDK.sh — build CoreCLR runtime + BCL from dotnet/runtime source
# and populate the CoreClrSDK platform directory.
#
# Usage:
#   ./BuildCoreClrSDK.sh <dotnet-runtime-dir> <platform> [build-type]
#
# Arguments:
#   dotnet-runtime-dir   Path to dotnet/runtime repository clone
#   platform             Target platform: win64 | linux | macos | android | ios | iossimulator
#   build-type           Debug (default) or Release
#
# Build subsets used (same for all platforms):
#   clr.runtime+clr.alljits+clr.corelib+clr.nativecorelib+clr.tools+clr.packages+libs
#
# Each platform produces:
#   <platform>/lib/       — native runtime (.so / .dylib / .dll)
#   <platform>/runtime/   — BCL managed .dll

set -euo pipefail

RUNTIME_DIR="${1:-}"
PLATFORM="${2:-}"
BUILD_TYPE="${3:-Debug}"

if [ -z "$RUNTIME_DIR" ] || [ -z "$PLATFORM" ]; then
    echo "Usage: $0 <dotnet-runtime-dir> <platform> [build-type]" >&2
    echo "  platforms: win64 | linux | macos | android | ios | iossimulator" >&2
    exit 1
fi

RUNTIME_DIR="$(cd "$RUNTIME_DIR" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/$PLATFORM"

echo "=== BuildCoreClrSDK ==="
echo "  Runtime dir : $RUNTIME_DIR"
echo "  Platform    : $PLATFORM"
echo "  Build type  : $BUILD_TYPE"
echo "  Output dir  : $OUTPUT_DIR"
echo ""

# ── Map platform to build arguments and artifact paths ─────────────────────
OS_ARG=""
ARCH_ARG=""
RUNTIME_ID=""
DOTNET_TFM="net10.0"

case "$PLATFORM" in
    win64)
        RUNTIME_ID="win-x64"
        ;;
    linux)
        RUNTIME_ID="linux-x64"
        ;;
    macos)
        RUNTIME_ID="osx-arm64"
        ;;
    android)
        OS_ARG="-os android"
        ARCH_ARG="-arch arm64"
        RUNTIME_ID="android-arm64"
        ;;
    ios)
        OS_ARG="-os ios"
        RUNTIME_ID="ios-arm64"
        ;;
    iossimulator)
        OS_ARG="-os iossimulator"
        ARCH_ARG="-arch arm64"
        RUNTIME_ID="iossimulator-arm64"
        ;;
    *)
        echo "ERROR: unknown platform '$PLATFORM'" >&2
        exit 1
        ;;
esac

# ── Step 1: Build CoreCLR + BCL ───────────────────────────────────────────
# Full subset matching Android's documented build command.
# This produces: native runtime, all JITs, managed CoreLib, native CoreLib,
# tools, packages, and the full BCL libs.
echo ">>> Building CoreCLR for $PLATFORM..."
cd "$RUNTIME_DIR"
./build.sh clr.runtime+clr.alljits+clr.corelib+clr.nativecorelib+clr.tools+clr.packages+libs \
    $OS_ARG $ARCH_ARG -configuration "$BUILD_TYPE"

# ── Step 2: Locate artifacts ──────────────────────────────────────────────
# ALL platforms: primary source is the runtime pack (produced by libs subset).
# It contains both native libs AND managed BCL DLLs.
RUNTIME_PACK="$RUNTIME_DIR/artifacts/bin/microsoft.netcore.app.runtime.$RUNTIME_ID/$BUILD_TYPE/runtimes/$RUNTIME_ID"
RUNTIME_PACK_NATIVE="$RUNTIME_PACK/native"
RUNTIME_PACK_MANAGED="$RUNTIME_PACK/lib/$DOTNET_TFM"

# CoreCLR artifacts dir — used only for pure-IL System.Private.CoreLib.dll.
# Path pattern varies by platform: <os>.<arch>.<Config>
case "$PLATFORM" in
    win64)    CORECLR_DIR="$RUNTIME_DIR/artifacts/bin/coreclr/win.x64.$BUILD_TYPE" ;;
    linux)    CORECLR_DIR="$RUNTIME_DIR/artifacts/bin/coreclr/linux.x64.$BUILD_TYPE" ;;
    macos)    CORECLR_DIR="$RUNTIME_DIR/artifacts/bin/coreclr/osx.arm64.$BUILD_TYPE" ;;
    android)  CORECLR_DIR="$RUNTIME_DIR/artifacts/bin/coreclr/android.arm64.$BUILD_TYPE" ;;
    ios)      CORECLR_DIR="$RUNTIME_DIR/artifacts/bin/coreclr/ios.arm64.$BUILD_TYPE" ;;
    iossimulator) CORECLR_DIR="$RUNTIME_DIR/artifacts/bin/coreclr/iossimulator.arm64.$BUILD_TYPE" ;;
esac
CORECLR_IL="$CORECLR_DIR/IL/System.Private.CoreLib.dll"

echo "  Runtime pack native : $RUNTIME_PACK_NATIVE"
echo "  Runtime pack managed: $RUNTIME_PACK_MANAGED"
echo "  CoreCLR IL CoreLib  : $CORECLR_IL"

# ── Step 3: Copy native libraries → <platform>/lib/ ───────────────────────
echo ""
echo ">>> Copying native libraries..."

mkdir -p "$OUTPUT_DIR/lib"
rm -f "$OUTPUT_DIR/lib"/*

# Determine file extension
case "$PLATFORM" in
    win64) NATIVE_EXT="dll" ;;
    linux|android) NATIVE_EXT="so" ;;
    macos|ios|iossimulator) NATIVE_EXT="dylib" ;;
esac

# Source 1: CoreCLR artifacts — runtime engine dylibs (libcoreclr, libclrjit, libclrinterpreter)
# These are NOT in the runtime pack native/ on most platforms.
if [ -d "$CORECLR_DIR" ]; then
    shopt -s nullglob
    for lib in libcoreclr libclrjit libclrinterpreter; do
        # Pick the exact-name dylib; skip cross-compiled variants (libclrjit_*.dylib etc.)
        for src in "$CORECLR_DIR/${lib}.${NATIVE_EXT}"; do
            if [ -f "$src" ]; then
                cp "$src" "$OUTPUT_DIR/lib/"
                echo "  $(basename "$src")"
            fi
        done
    done
    shopt -u nullglob
fi

# Source 2: Runtime pack native — system shim dylibs
# (libSystem.Native, libSystem.Globalization.Native, etc.)
if [ -d "$RUNTIME_PACK_NATIVE" ]; then
    for lib in libSystem.Native libSystem.IO.Compression.Native libSystem.Globalization.Native libSystem.Net.Security.Native libSystem.Security.Cryptography.Native.Apple; do
        src="$RUNTIME_PACK_NATIVE/${lib}.${NATIVE_EXT}"
        if [ -f "$src" ]; then
            cp "$src" "$OUTPUT_DIR/lib/"
            echo "  ${lib}.${NATIVE_EXT}"
        fi
    done
fi

NATIVE_COUNT=$(find "$OUTPUT_DIR/lib" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
echo "  Total: ${NATIVE_COUNT} native files"

# ── Step 4: Copy BCL managed DLLs → <platform>/runtime/ ───────────────────
echo ""
echo ">>> Copying BCL managed DLLs..."

mkdir -p "$OUTPUT_DIR/runtime"
rm -f "$OUTPUT_DIR/runtime"/*

# Step 4a: Pure-IL System.Private.CoreLib.dll (iOS/iOS Simulator: required for interpreter)
CORECLR_PDB="$CORECLR_DIR/IL/System.Private.CoreLib.pdb"
if [ -f "$CORECLR_IL" ]; then
    cp "$CORECLR_IL" "$OUTPUT_DIR/runtime/System.Private.CoreLib.dll"
    echo "  System.Private.CoreLib.dll (pure-IL from CoreCLR IL/)"
    # Also copy matching pdb if available
    if [ -f "$CORECLR_PDB" ]; then
        cp "$CORECLR_PDB" "$OUTPUT_DIR/runtime/System.Private.CoreLib.pdb"
        echo "  System.Private.CoreLib.pdb (from CoreCLR IL/)"
    fi
else
    echo "  NOTE: CoreCLR IL/ CoreLib not found, will use runtime pack version"
fi

# Step 4b: All BCL DLLs from runtime pack managed dir
if [ -d "$RUNTIME_PACK_MANAGED" ]; then
    for dll in "$RUNTIME_PACK_MANAGED"/*.dll; do
        name=$(basename "$dll")
        # Don't overwrite pure-IL CoreLib if we already placed it
        if [ "$name" = "System.Private.CoreLib.dll" ] && [ -f "$OUTPUT_DIR/runtime/System.Private.CoreLib.dll" ]; then
            continue
        fi
        cp "$dll" "$OUTPUT_DIR/runtime/"
    done
    DLL_COUNT=$(find "$OUTPUT_DIR/runtime" -maxdepth 1 -name "*.dll" 2>/dev/null | wc -l | tr -d ' ')
    echo "  Total: ${DLL_COUNT} BCL .dll files from $RUNTIME_PACK_MANAGED"
else
    echo "  ERROR: Runtime pack managed DLLs not found at $RUNTIME_PACK_MANAGED"
    echo "  The 'libs' subset may not have built correctly."
    exit 1
fi

# Step 4c: Copy BCL PDBs (stack traces need them for line numbers)
RUNTIME_PACK_PDB="$RUNTIME_PACK/lib/$DOTNET_TFM"
PDB_COUNT=0
for pdb in "$RUNTIME_PACK_PDB"/*.pdb; do
    if [ -f "$pdb" ]; then
        cp "$pdb" "$OUTPUT_DIR/runtime/"
        PDB_COUNT=$((PDB_COUNT + 1))
    fi
done
if [ $PDB_COUNT -gt 0 ]; then
    echo "  Total: ${PDB_COUNT} BCL .pdb files"
fi

# ── Step 5: iOS-specific: build .embeddedframework.zip ────────────────────
case "$PLATFORM" in
    ios|iossimulator)
        echo ""
        echo ">>> Building .embeddedframework.zip files..."
        bash "$SCRIPT_DIR/MakeCoreClrFramework.sh" "$PLATFORM" "$OUTPUT_DIR/lib" "$OUTPUT_DIR/lib"
        ;;
esac

# ── Step 6: Summary ───────────────────────────────────────────────────────
echo ""
echo "=== Done. CoreClrSDK populated for $PLATFORM ($BUILD_TYPE). ==="
echo "  Native:  $OUTPUT_DIR/lib/ ($(find "$OUTPUT_DIR/lib" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ') files)"
echo "  Managed: $OUTPUT_DIR/runtime/ ($(find "$OUTPUT_DIR/runtime" -maxdepth 1 -name '*.dll' 2>/dev/null | wc -l | tr -d ' ') DLLs)"
