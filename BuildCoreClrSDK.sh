#!/usr/bin/env bash
# BuildCoreClrSDK.sh — build CoreCLR runtime + BCL from dotnet/runtime source.
#
# This script ONLY builds. Use CopySDKFromSrc.sh afterwards to populate the
# SDK platform directory with the build artifacts.
#
# Usage:
#   ./BuildCoreClrSDK.sh <dotnet-runtime-dir> <platform> [build-type]
#
# Arguments:
#   dotnet-runtime-dir   Path to dotnet/runtime repository clone
#   platform             Target platform: win64 | linux | macos | android | ios | iossimulator
#   build-type           Debug (default) or Release
#
# Build subsets: clr.runtime+clr.alljits+clr.corelib+clr.nativecorelib+
#                 clr.tools+clr.packages+libs

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

echo "=== BuildCoreClrSDK ==="
echo "  Runtime dir : $RUNTIME_DIR"
echo "  Platform    : $PLATFORM"
echo "  Build type  : $BUILD_TYPE"

# ── Map platform to build arguments ────────────────────────────────────────
OS_ARG=""
ARCH_ARG=""
case "$PLATFORM" in
    win64) ;;
    linux) ;;
    macos) ;;
    android)    OS_ARG="-os android";     ARCH_ARG="-arch arm64" ;;
    ios)        OS_ARG="-os ios" ;;
    iossimulator) OS_ARG="-os iossimulator"; ARCH_ARG="-arch arm64" ;;
    *)
        echo "ERROR: unknown platform '$PLATFORM'" >&2
        exit 1
        ;;
esac

# ── Build ──────────────────────────────────────────────────────────────────
echo ">>> Building CoreCLR for $PLATFORM..."
cd "$RUNTIME_DIR"
./build.sh clr.runtime+clr.alljits+clr.corelib+clr.nativecorelib+clr.tools+clr.packages+libs \
    $OS_ARG $ARCH_ARG -configuration "$BUILD_TYPE"

echo ""
echo "=== Build done. Run CopySDKFromSrc.sh to populate the SDK directory. ==="
