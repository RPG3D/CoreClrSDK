#!/usr/bin/env bash
# FetchCoreClrSDK.sh — fast path for Android: download the android-arm64 CoreCLR
# runtime + BCL from NuGet and populate Android/arm64/{lib,runtime}.
#
# This skips the dotnet/runtime build entirely (hours -> minutes). It is only valid
# for Android, where the JIT consumes the ReadyToRun CoreLib from the runtime pack.
# iOS needs the pure-IL CoreLib produced by clr.corelib, so it requires a real build
# (BuildCoreClrSDK.sh ios | iossimulator).
#
# The CoreClrSDK binaries are git-ignored build artifacts; run this once after cloning
# (or when upgrading the .NET version). Mirrors how MonoSDK is populated from Releases.
#
# Usage:
#   ./FetchCoreClrSDK.sh                              # pinned version (DotNetRuntime.version)
#   ./FetchCoreClrSDK.sh 11.0.0-rc.1.26425.128        # explicit runtime version
#
# Requirements: curl (or wget) + unzip on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="$SCRIPT_DIR"
DEST="$SDK_ROOT/Android/arm64"
LIB_DIR="$DEST/lib"
RUNTIME_DIR="$DEST/runtime"

# Pinned runtime version/TFM — single source of truth: DotNetRuntime.version.
VERSION_FILE="$SDK_ROOT/DotNetRuntime.version"
RUNTIME_VERSION="$(grep -E '^RUNTIME_VERSION=' "$VERSION_FILE" | cut -d= -f2- | tr -d '\r')"
DOTNET_TFM="$(grep -E '^DOTNET_TFM=' "$VERSION_FILE" | cut -d= -f2- | tr -d '\r')"
BUILD_SUBSET="$(grep -E '^BUILD_SUBSET=' "$VERSION_FILE" | cut -d= -f2- | tr -d '\r')"
RUNTIME_VERSION="${1:-$RUNTIME_VERSION}"

RID="android-arm64"
NUGET_URL="https://globalcdn.nuget.org/packages/microsoft.netcore.app.runtime.${RID}.${RUNTIME_VERSION}.nupkg"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== FetchCoreClrSDK: .NET ${RUNTIME_VERSION} (${RID}) ==="
echo "SDK dir: $DEST"

NUPKG="$WORK_DIR/runtime.nupkg"
echo "Downloading $NUGET_URL ..."
if command -v curl >/dev/null 2>&1; then
    curl -sL --retry 3 "$NUGET_URL" -o "$NUPKG"
elif command -v wget >/dev/null 2>&1; then
    wget -q "$NUGET_URL" -O "$NUPKG"
else
    echo "ERROR: need curl or wget on PATH" >&2
    exit 1
fi

if [[ ! -s "$NUPKG" ]]; then
    echo "ERROR: download failed or empty (check version $RUNTIME_VERSION exists on NuGet)" >&2
    exit 1
fi

echo "Extracting nupkg ..."
unzip -q "$NUPKG" -d "$WORK_DIR/extracted"
PACK_ROOT="$WORK_DIR/extracted/runtimes/$RID"

if [[ ! -d "$PACK_ROOT" ]]; then
    echo "ERROR: runtime pack layout unexpected: $PACK_ROOT not found" >&2
    exit 1
fi

# Native .so -> Android/arm64/lib/. Copy the runtime engines + interop shims only:
# the pack also carries the debugger libraries (mscordaccore/mscordbi), which the
# host never loads and which would only bloat the APK.
mkdir -p "$LIB_DIR"
rm -f "$LIB_DIR"/*.so
for LIB in libcoreclr libclrjit libclrinterpreter \
           libSystem.Native \
           libSystem.IO.Compression.Native \
           libSystem.Globalization.Native \
           libSystem.Net.Security.Native \
           libSystem.Security.Cryptography.Native.Android; do
    SRC="$PACK_ROOT/native/${LIB}.so"
    if [[ -f "$SRC" ]]; then
        cp "$SRC" "$LIB_DIR/"
    fi
done
echo "Installed native .so to $LIB_DIR:"
ls -1 "$LIB_DIR"

# BCL managed .dll -> Android/arm64/runtime/.
mkdir -p "$RUNTIME_DIR"
rm -f "$RUNTIME_DIR"/*.dll
cp "$PACK_ROOT"/lib/${DOTNET_TFM}/*.dll "$RUNTIME_DIR"/
DLL_COUNT=$(ls -1 "$RUNTIME_DIR"/*.dll | wc -l | tr -d ' ')
echo "Installed $DLL_COUNT BCL .dll to $RUNTIME_DIR"

if [[ ! -f "$LIB_DIR/libcoreclr.so" ]]; then
    echo "ERROR: libcoreclr.so missing from the runtime pack." >&2
    exit 1
fi

cat > "$DEST/VERSION.txt" <<EOF
NuGet runtime pack (no source build)
  package: microsoft.netcore.app.runtime.${RID}
  version: ${RUNTIME_VERSION}

Platform: Android (arm64)
Build type: Release (NuGet)
Build subsets: ${BUILD_SUBSET} (runtime pack equivalent)
EOF

echo "=== Done. CoreClrSDK populated for ${RID} (.NET ${RUNTIME_VERSION}). ==="
