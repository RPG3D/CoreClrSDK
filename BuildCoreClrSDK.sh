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
# Platforms and build commands:
#   win64           ./build.sh clr.native+clr.corelib -configuration <type>
#   linux           ./build.sh clr.native+clr.corelib -configuration <type>
#   macos           ./build.sh clr.native+clr.corelib -configuration <type>
#   android         ./build.sh clr.native+clr.corelib -os android -arch arm64 -configuration <type>
#   ios             ./build.sh clr.native+clr.corelib -os ios -configuration <type>
#   iossimulator    ./build.sh clr.native+clr.corelib -os iossimulator -arch arm64 -configuration <type>
#
# Each platform produces:
#   <platform>/lib/       — native runtime (.so / .dylib)
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
BUILD_TYPE_CAP="$(tr '[:lower:]' '[:upper:]' <<< "${BUILD_TYPE:0:1}")${BUILD_TYPE:1}"
OUTPUT_DIR="$SCRIPT_DIR/$PLATFORM"

echo "=== BuildCoreClrSDK ==="
echo "  Runtime dir : $RUNTIME_DIR"
echo "  Platform    : $PLATFORM"
echo "  Build type  : $BUILD_TYPE"
echo "  Output dir  : $OUTPUT_DIR"
echo ""

# ── Map platform to build arguments ────────────────────────────────────────
OS_ARG=""
ARCH_ARG=""
case "$PLATFORM" in
    win64)
        ;;
    linux)
        ;;
    macos)
        ;;
    android)
        OS_ARG="-os android"
        ARCH_ARG="-arch arm64"
        ;;
    ios)
        OS_ARG="-os ios"
        ;;
    iossimulator)
        OS_ARG="-os iossimulator"
        ARCH_ARG="-arch arm64"
        ;;
    *)
        echo "ERROR: unknown platform '$PLATFORM'" >&2
        exit 1
        ;;
esac

# ── Step 1: Build CoreCLR native + managed CoreLib ────────────────────────
echo ""
echo ">>> Building CoreCLR (Clr.Native + clr.corelib) for $PLATFORM..."
cd "$RUNTIME_DIR"
./build.sh clr.native+clr.corelib $OS_ARG $ARCH_ARG -configuration "$BUILD_TYPE"

# ── Step 2: Locate build artifacts ────────────────────────────────────────
echo ""
echo ">>> Locating build artifacts..."

# Platform-specific artifact paths
case "$PLATFORM" in
    win64)
        CORECLR_ARTIFACTS="$RUNTIME_DIR/artifacts/bin/coreclr/win.x64.$BUILD_TYPE"
        RUNTIME_PACK="$RUNTIME_DIR/artifacts/bin/microsoft.netcore.app.runtime.win-x64/$BUILD_TYPE/runtimes/win-x64"
        ;;
    linux)
        CORECLR_ARTIFACTS="$RUNTIME_DIR/artifacts/bin/coreclr/linux.x64.$BUILD_TYPE"
        RUNTIME_PACK="$RUNTIME_DIR/artifacts/bin/microsoft.netcore.app.runtime.linux-x64/$BUILD_TYPE/runtimes/linux-x64"
        ;;
    macos)
        CORECLR_ARTIFACTS="$RUNTIME_DIR/artifacts/bin/coreclr/osx.arm64.$BUILD_TYPE"
        RUNTIME_PACK="$RUNTIME_DIR/artifacts/bin/microsoft.netcore.app.runtime.osx-arm64/$BUILD_TYPE/runtimes/osx-arm64"
        ;;
    android)
        CORECLR_ARTIFACTS="$RUNTIME_DIR/artifacts/bin/coreclr/android.arm64.$BUILD_TYPE"
        RUNTIME_PACK="$RUNTIME_DIR/artifacts/bin/microsoft.netcore.app.runtime.android-arm64/$BUILD_TYPE/runtimes/android-arm64"
        ;;
    ios)
        CORECLR_ARTIFACTS="$RUNTIME_DIR/artifacts/bin/coreclr/ios.arm64.$BUILD_TYPE"
        RUNTIME_PACK="$RUNTIME_DIR/artifacts/bin/microsoft.netcore.app.runtime.ios-arm64/$BUILD_TYPE/runtimes/ios-arm64"
        ;;
    iossimulator)
        CORECLR_ARTIFACTS="$RUNTIME_DIR/artifacts/bin/coreclr/iossimulator.arm64.$BUILD_TYPE"
        RUNTIME_PACK="$RUNTIME_DIR/artifacts/bin/microsoft.netcore.app.runtime.iossimulator-arm64/$BUILD_TYPE/runtimes/iossimulator-arm64"
        ;;
esac

echo "  CoreCLR artifacts : $CORECLR_ARTIFACTS"
echo "  Runtime pack      : $RUNTIME_PACK"

# ── Step 3: Copy native libraries → <platform>/lib/ ───────────────────────
echo ""
echo ">>> Copying native libraries..."

mkdir -p "$OUTPUT_DIR/lib"
rm -f "$OUTPUT_DIR/lib"/*

# CoreCLR native runtime files
copy_native_coreclr() {
    local src_dir="$1"
    local dst_dir="$2"
    local ext="$3"

    # CoreCLR runtime
    for f in coreclr clrjit clrinterpreter; do
        if [ -f "$src_dir/lib${f}.${ext}" ]; then
            cp "$src_dir/lib${f}.${ext}" "$dst_dir/"
            echo "  lib${f}.${ext}"
        fi
    done
}

# System native shims (from runtime pack)
copy_native_shims() {
    local src_dir="$1"
    local dst_dir="$2"
    local ext="$3"

    for f in System.Native System.IO.Compression.Native System.Globalization.Native \
             System.Net.Security.Native System.Security.Cryptography.Native.Apple; do
        if [ -f "$src_dir/lib${f}.${ext}" ]; then
            cp "$src_dir/lib${f}.${ext}" "$dst_dir/"
            echo "  lib${f}.${ext}"
        fi
    done
}

NATIVE_EXT="so"
RUNTIME_PACK_NATIVE="$RUNTIME_PACK/native"
case "$PLATFORM" in
    win64)
        NATIVE_EXT="dll"
        RUNTIME_PACK_NATIVE="$RUNTIME_PACK/native"
        ;;
    linux|android)
        NATIVE_EXT="so"
        RUNTIME_PACK_NATIVE="$RUNTIME_PACK/native"
        ;;
    macos|ios|iossimulator)
        NATIVE_EXT="dylib"
        RUNTIME_PACK_NATIVE="$RUNTIME_PACK/native"
        ;;
esac

if [ -d "$CORECLR_ARTIFACTS" ]; then
    copy_native_coreclr "$CORECLR_ARTIFACTS" "$OUTPUT_DIR/lib" "$NATIVE_EXT"
fi
if [ -d "$RUNTIME_PACK_NATIVE" ]; then
    copy_native_shims "$RUNTIME_PACK_NATIVE" "$OUTPUT_DIR/lib" "$NATIVE_EXT"
fi

NATIVE_COUNT=$(ls -1 "$OUTPUT_DIR/lib"/*.${NATIVE_EXT} 2>/dev/null | wc -l | tr -d ' ')
echo "  Total: ${NATIVE_COUNT} native .${NATIVE_EXT} files"

# ── Step 4: Copy BCL managed DLLs → <platform>/runtime/ ───────────────────
echo ""
echo ">>> Copying BCL managed DLLs..."

mkdir -p "$OUTPUT_DIR/runtime"
rm -f "$OUTPUT_DIR/runtime"/*

# Use the pure-IL System.Private.CoreLib.dll from CoreCLR build (avoids System.__Canon issue)
CORECLR_IL="$CORECLR_ARTIFACTS/IL/System.Private.CoreLib.dll"
if [ -f "$CORECLR_IL" ]; then
    cp "$CORECLR_IL" "$OUTPUT_DIR/runtime/System.Private.CoreLib.dll"
    echo "  System.Private.CoreLib.dll (pure-IL from CoreCLR IL/)"
else
    echo "  WARNING: CoreCLR IL/ System.Private.CoreLib.dll not found, will use testhost version"
fi

# Copy remaining BCL from testhost
# BCL version subdir — auto-detect from testhost path
BCL_SRC=""
for ver_dir in "$RUNTIME_DIR/artifacts/bin/testhost/"*"-$PLATFORM-$BUILD_TYPE"*"/shared/Microsoft.NETCore.App/"*/; do
    if [ -d "$ver_dir" ]; then
        BCL_SRC="$ver_dir"
        break
    fi
done

if [ -z "$BCL_SRC" ]; then
    # Fallback: try to find BCL from runtime pack managed dir
    BCL_SRC="$RUNTIME_PACK/lib/net10.0"
    if [ ! -d "$BCL_SRC" ]; then
        BCL_SRC="$RUNTIME_PACK/lib/net10.0"
    fi
fi

if [ -d "$BCL_SRC" ]; then
    for dll in "$BCL_SRC"/*.dll; do
        name=$(basename "$dll")
        # Don't overwrite the pure-IL CoreLib we already placed
        if [ "$name" != "System.Private.CoreLib.dll" ] || [ ! -f "$OUTPUT_DIR/runtime/System.Private.CoreLib.dll" ]; then
            cp "$dll" "$OUTPUT_DIR/runtime/"
        fi
    done
    DLL_COUNT=$(ls -1 "$OUTPUT_DIR/runtime"/*.dll 2>/dev/null | wc -l | tr -d ' ')
    echo "  Total: ${DLL_COUNT} BCL .dll files from $BCL_SRC"
else
    echo "  WARNING: BCL source directory not found"
    # Try runtime pack fallback
    RUNTIME_MANAGED="$RUNTIME_PACK/lib/net10.0"
    if [ -d "$RUNTIME_MANAGED" ]; then
        cp "$RUNTIME_MANAGED"/*.dll "$OUTPUT_DIR/runtime/" 2>/dev/null || true
        DLL_COUNT=$(ls -1 "$OUTPUT_DIR/runtime"/*.dll 2>/dev/null | wc -l | tr -d ' ')
        echo "  Fallback: ${DLL_COUNT} BCL .dll files from $RUNTIME_MANAGED"
    fi
fi

# ── Step 5: iOS-specific: build .embeddedframework.zip ────────────────────
case "$PLATFORM" in
    ios|iossimulator)
        echo ""
        echo ">>> Building .embeddedframework.zip files..."
        bash "$SCRIPT_DIR/MakeCoreClrFramework.sh" "$PLATFORM" "$OUTPUT_DIR/lib" "$OUTPUT_DIR/lib"
        ;;
esac

echo ""
echo "=== Done. CoreClrSDK populated for $PLATFORM ($BUILD_TYPE). ==="
echo "  Native:  $OUTPUT_DIR/lib/"
echo "  Managed: $OUTPUT_DIR/runtime/"
