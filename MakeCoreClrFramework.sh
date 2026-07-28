#!/usr/bin/env bash
# MakeCoreClrFramework.sh
# Build .embeddedframework.zip files for iOS / iOS Simulator CoreCLR runtime.
#
# Each native dylib gets its own .embeddedframework.zip so UBT can stage them
# into IPA/Frameworks/ via PublicAdditionalFrameworks. This matches the proven
# IOSClrDemo pattern (one .framework per dylib), which was extensively debugged.
#
# The framework binary IS the real dylib (not a stub) — CoreCLR is dynamically
# linked via LC_LOAD_DYLIB, not statically linked. This is required because
# CoreCLR uses _dyld_get_image_name(0) to locate its own path.
#
# Usage:
#   ./MakeCoreClrFramework.sh <platform> <dylibs-dir> <output-lib-dir>
#
# Arguments:
#   platform          ios | iossimulator
#   dylibs-dir        Path to directory containing native .dylib files
#   output-lib-dir    Path to SDK lib/ directory where .embeddedframework.zip goes
#
# Examples:
#   ./MakeCoreClrFramework.sh iossimulator libs/ iOSSimulator/lib/

set -euo pipefail

PLATFORM="${1:-}"
DYLIBS_DIR="${2:-}"
OUTPUT_DIR="${3:-}"

if [[ -z "$PLATFORM" || -z "$DYLIBS_DIR" || -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <platform> <dylibs-dir> <output-lib-dir>" >&2
    echo "  platform: ios | iossimulator" >&2
    exit 1
fi

if [[ "$PLATFORM" != "ios" && "$PLATFORM" != "iossimulator" ]]; then
    echo "Error: platform must be 'ios' or 'iossimulator', got '$PLATFORM'" >&2
    exit 1
fi

DYLIBS_DIR="$(cd "$DYLIBS_DIR" && pwd)"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" 2>/dev/null && pwd)" || true
if [[ -z "$OUTPUT_DIR" ]]; then
    mkdir -p "${3}"
    OUTPUT_DIR="$(cd "${3}" && pwd)"
fi

echo "=== MakeCoreClrFramework ==="
echo "  Platform  : $PLATFORM"
echo "  Dylibs dir: $DYLIBS_DIR"
echo "  Output dir: $OUTPUT_DIR"
echo ""

# Each dylib gets its own .embeddedframework.zip.
# CoreCLR runtime dylibs (linked by host or loaded by CoreCLR at runtime):
#   libcoreclr.dylib      — host links this directly
#   libclrjit.dylib       — loaded by CoreCLR at runtime (not used in interpreter mode, but present)
#   libclrinterpreter.dylib — loaded by CoreCLR in interpreter mode
# System native shims (loaded by CoreCLR P/Invoke at runtime):
#   libSystem.Native.dylib
#   libSystem.IO.Compression.Native.dylib
#   libSystem.Net.Security.Native.dylib
#   libSystem.Security.Cryptography.Native.Apple.dylib
#   libSystem.Globalization.Native.dylib

for DYLIB_PATH in "$DYLIBS_DIR"/*.dylib; do
    if [[ ! -f "$DYLIB_PATH" ]]; then
        continue
    fi

    DYLIB_NAME="$(basename "$DYLIB_PATH")"
    # Framework name = dylib name minus ".dylib" suffix
    # e.g. libcoreclr.dylib -> libcoreclr
    FW_NAME="${DYLIB_NAME%.dylib}"

    echo ">>> Building ${FW_NAME}.embeddedframework.zip ..."

    FW_WORK="$(mktemp -d)"
    FW_EMBEDDED="$FW_WORK/${FW_NAME}.embeddedframework"
    FW_ROOT="$FW_EMBEDDED/${FW_NAME}.framework"
    mkdir -p "$FW_ROOT"

    # Copy the REAL dylib as the framework binary (not a stub!)
    cp "$DYLIB_PATH" "$FW_ROOT/$FW_NAME"
    chmod +x "$FW_ROOT/$FW_NAME"

    # Generate Info.plist (required for dyld validation)
    cat > "$FW_ROOT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${FW_NAME}</string>
    <key>CFBundleIdentifier</key><string>com.unrealsharp.${FW_NAME}</string>
    <key>CFBundleName</key><string>${FW_NAME}</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>MinimumOSVersion</key><string>15.0</string>
</dict>
</plist>
PLIST

    # Pack into .embeddedframework.zip (UE5's expected format)
    cd "$FW_WORK"
    zip -r --symlinks "$OUTPUT_DIR/${FW_NAME}.embeddedframework.zip" "${FW_NAME}.embeddedframework" > /dev/null
    rm -rf "$FW_WORK"

    echo "    Created: $OUTPUT_DIR/${FW_NAME}.embeddedframework.zip"
done

echo ""
echo "=== Done. $(ls -1 "$OUTPUT_DIR"/*.embeddedframework.zip 2>/dev/null | wc -l | tr -d ' ') embedded framework zips created. ==="
