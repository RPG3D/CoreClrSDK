#!/usr/bin/env bash
# FetchCoreClrSDK_iOS.sh — copy iOS Simulator CoreCLR runtime + BCL from a local
# DotNet10 build into Source/ThirdParty/CoreClrSDK/iOSSimulator/{lib,runtime}.
#
# Sources from the SELF-CONSISTENT runtime-pack artifacts built from DotNet10
# (verified working in IOSClrDemo). The native runtime and BCL MUST match the
# same runtime-pack version, otherwise coreclr_initialize aborts hard.
#
# Key fix from DotNet10 vs DotNet11: uses the CoreCLR IL/ directory's pure IL
# System.Private.CoreLib.dll to avoid System.__Canon type loading failures.
# DotNet10 also fixes the coreclr_execute_assembly SIGABRT crash that DotNet11 has.
#
# Also runs MakeCoreClrFramework.sh to create .embeddedframework.zip files for UBT.
#
# The CoreClrSDK binaries (.dylib / .dll) are git-ignored (large, version-bound).
# Run this script once after cloning (or when rebuilding DotNet10).
#
# Prerequisites:
#   DotNet10 built for iossimulator-arm64:
#     cd /Users/admin/Documents/Code/DotNet
#     ./eng/build.sh --os iossimulator --arch arm64 --configuration Debug --subset Clr.Native
#
# Usage:
#   ./FetchCoreClrSDK_iOS.sh                                    # default DotNet11 path
#   ./FetchCoreClrSDK_iOS.sh /path/to/DotNet                    # explicit DotNet11 path
#
# Reference: IOSClrDemo/build.sh (Step 0 + Step 2) — DotNet11 adaptation

set -euo pipefail

DOTNET11_ROOT="${1:-/Users/admin/Documents/Code/DotNet}"

# Resolve the SDK root (directory containing this script).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="$SCRIPT_DIR"
PLATFORM_DIR="$SDK_ROOT/iOSSimulator"
LIB_DIR="$PLATFORM_DIR/lib"
RUNTIME_DIR="$PLATFORM_DIR/runtime"

# Pinned runtime version/TFM — single source of truth: DotNetRuntime.version.
DOTNET_TFM="$(grep -E '^DOTNET_TFM=' "$SDK_ROOT/DotNetRuntime.version" | cut -d= -f2- | tr -d '\r')"
RUNTIME_VERSION="$(grep -E '^RUNTIME_VERSION=' "$SDK_ROOT/DotNetRuntime.version" | cut -d= -f2- | tr -d '\r')"

echo "=== FetchCoreClrSDK_iOS: DotNet10 (iossimulator-arm64) ==="
echo "DotNet11 root: $DOTNET11_ROOT"
echo "SDK root: $SDK_ROOT"

# ── Source paths (matching IOSClrDemo/build.sh, adapted for DotNet10) ────
# Native dylibs from the self-consistent runtime-pack artifacts.
RUNTIME_PACK_ARTIFACTS="${DOTNET11_ROOT}/artifacts/bin/microsoft.netcore.app.runtime.iossimulator-arm64/Debug"
NATIVE_SRC="${RUNTIME_PACK_ARTIFACTS}/runtimes/iossimulator-arm64/native"

# CoreCLR native dylibs (libcoreclr, libclrjit, libclrinterpreter)
CORECLR_NATIVE="${DOTNET11_ROOT}/artifacts/bin/coreclr/iossimulator.arm64.Debug"

# CoreCLR IL directory — pure IL System.Private.CoreLib.dll
# Using this instead of the testhost BCL version avoids System.__Canon loading failures.
CORECLR_IL="${CORECLR_NATIVE}/IL"

# BCL from the testhost shared framework (version-matched to native runtime).
BCL_SRC="${DOTNET11_ROOT}/artifacts/bin/testhost/${DOTNET_TFM}-iossimulator-Debug-arm64/shared/Microsoft.NETCore.App/${RUNTIME_VERSION}"

if [ ! -f "${CORECLR_NATIVE}/libcoreclr.dylib" ]; then
    echo "  ERROR: libcoreclr.dylib not found at ${CORECLR_NATIVE}"
    echo "  Build DotNet11 CoreCLR first:"
    echo "    cd ${DOTNET11_ROOT}"
    echo "    ./eng/build.sh --os iossimulator --arch arm64 --configuration Debug --subset Clr.Native"
    exit 1
fi

if [ ! -d "${NATIVE_SRC}" ]; then
    echo "  WARNING: runtime-pack native dir not found at ${NATIVE_SRC}"
    echo "  System dylibs may be missing. Continuing with CoreCLR dylibs only."
fi

if [ ! -d "${BCL_SRC}" ]; then
    echo "  WARNING: BCL dir not found at ${BCL_SRC}"
    echo "  BCL DLLs may be missing."
fi

# ── Step 1: Copy native dylibs → iOSSimulator/lib/ ───────────────────────
mkdir -p "$LIB_DIR"
rm -f "$LIB_DIR"/*.dylib "$LIB_DIR"/*.embeddedframework.zip

# CoreCLR runtime dylibs from CoreCLR native build
for f in libcoreclr.dylib libclrjit.dylib libclrinterpreter.dylib; do
    if [ -f "${CORECLR_NATIVE}/${f}" ]; then
        cp "${CORECLR_NATIVE}/${f}" "${LIB_DIR}/"
    fi
done

# System native shims from runtime pack
if [ -d "${NATIVE_SRC}" ]; then
    for f in libSystem.Native.dylib libSystem.IO.Compression.Native.dylib \
             libSystem.Globalization.Native.dylib libSystem.Net.Security.Native.dylib \
             libSystem.Security.Cryptography.Native.Apple.dylib; do
        if [ -f "${NATIVE_SRC}/${f}" ]; then
            cp "${NATIVE_SRC}/${f}" "${LIB_DIR}/"
        fi
    done
fi
echo "Copied $(ls -1 "${LIB_DIR}"/*.dylib 2>/dev/null | wc -l | tr -d ' ') .dylib files to ${LIB_DIR}"

# ── Step 2: Copy BCL DLLs → iOSSimulator/runtime/ ────────────────────────
mkdir -p "$RUNTIME_DIR"
rm -f "$RUNTIME_DIR"/*.dll

if [ -d "${BCL_SRC}" ]; then
    cp "${BCL_SRC}"/*.dll "${RUNTIME_DIR}/"
fi

# Use the CoreCLR IL/ directory's pure IL System.Private.CoreLib.dll
# to avoid System.__Canon type loading failures (known DotNet10 fix).
if [ -f "${CORECLR_IL}/System.Private.CoreLib.dll" ]; then
    cp "${CORECLR_IL}/System.Private.CoreLib.dll" "${RUNTIME_DIR}/"
    echo "  Replaced System.Private.CoreLib.dll with pure IL version from CoreCLR IL/"
fi

DLL_COUNT=$(ls -1 "${RUNTIME_DIR}"/*.dll 2>/dev/null | wc -l | tr -d ' ')
echo "Copied ${DLL_COUNT} BCL .dll files to ${RUNTIME_DIR}"

# ── Step 3: Build .embeddedframework.zip files ───────────────────────────
echo ""
echo "Building .embeddedframework.zip files..."
bash "$SCRIPT_DIR/MakeCoreClrFramework.sh" iossimulator "$LIB_DIR" "$LIB_DIR"

echo ""
echo "=== Done. CoreClrSDK populated for iossimulator-arm64 (DotNet11). ==="
echo "iOSSimulator/lib:     $(ls -1 "$LIB_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ') dylibs, $(ls -1 "$LIB_DIR"/*.embeddedframework.zip 2>/dev/null | wc -l | tr -d ' ') framework zips"
echo "iOSSimulator/runtime: ${DLL_COUNT} BCL .dll files"
