#!/usr/bin/env bash
# MakeCoreClrFramework.sh
# Build a SINGLE CoreCLR.embeddedframework.zip for iOS / iOS Simulator.
#
# All CoreCLR native dylibs are packaged into one umbrella framework (mirrors
# MonoSDK's Mono.embeddedframework.zip layout), instead of one framework per dylib:
#   CoreCLR.framework/CoreCLR      <- libcoreclr.dylib (REAL runtime binary, not a stub)
#   CoreCLR.framework/Frameworks/  <- other runtime dylibs (libclrjit, libclrinterpreter,
#                                     libSystem.* native shims)
#   CoreCLR.framework/Info.plist
#
# UBT stages the framework into IPA/Frameworks/ via PublicAdditionalFrameworks
# (LinkAndCopy in CoreClrSDK.Build.cs): the linker resolves coreclr_* symbols from
# CoreCLR.framework/CoreCLR, and the whole framework (with sub-Frameworks/) is copied
# into the .app bundle.
#
# The framework binary IS the real libcoreclr.dylib (not a stub) - CoreCLR is
# dynamically linked via LC_LOAD_DYLIB, and uses _dyld_get_image_name(0) to locate
# its own path at runtime.
#
# NOTE (@rpath): the sub-framework dylibs in CoreCLR.framework/Frameworks/ are loaded
# by CoreCLR at runtime via dlopen. dyld's default @rpath (@executable_path/Frameworks)
# does NOT resolve into a framework's inner Frameworks/ dir, so if CoreCLR fails to
# load libclrjit/libSystem.* at runtime, adjust the dylib install_names here with
# install_name_tool -id @rpath/CoreCLR.framework/Frameworks/<name> (requires Mac/iOS
# testing to confirm).
#
# Usage:
#   ./MakeCoreClrFramework.sh <platform> <dylibs-dir> <output-lib-dir>
#   platform: ios

set -euo pipefail

PLATFORM="${1:-}"
DYLIBS_DIR="${2:-}"
OUTPUT_DIR="${3:-}"

if [[ -z "$PLATFORM" || -z "$DYLIBS_DIR" || -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <platform> <dylibs-dir> <output-lib-dir>" >&2
    echo "  platform: ios" >&2
    exit 1
fi

if [[ "$PLATFORM" != "ios" ]]; then
    echo "Error: platform must be 'ios', got '$PLATFORM'" >&2
    exit 1
fi

DYLIBS_DIR="$(cd "$DYLIBS_DIR" && pwd)"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" 2>/dev/null && pwd)" || true
if [[ -z "$OUTPUT_DIR" ]]; then
    mkdir -p "${3}"
    OUTPUT_DIR="$(cd "${3}" && pwd)"
fi

echo "=== MakeCoreClrFramework (single umbrella framework) ==="
echo "  Platform  : $PLATFORM"
echo "  Dylibs dir: $DYLIBS_DIR"
echo "  Output dir: $OUTPUT_DIR"

# The main framework binary is libcoreclr.dylib (real runtime - NOT a stub).
# The host links coreclr_* symbols from it; CoreCLR uses _dyld_get_image_name(0)
# to locate its own path.
CORECLR_DYLIB="$DYLIBS_DIR/libcoreclr.dylib"
if [[ ! -f "$CORECLR_DYLIB" ]]; then
    echo "Error: libcoreclr.dylib not found in $DYLIBS_DIR" >&2
    exit 1
fi

# Other runtime dylibs packaged into the framework's Frameworks/ subdirectory.
# Loaded by CoreCLR at runtime (JIT/interpreter + P/Invoke native shims).
OTHER_DYLIBS=(
    libclrjit.dylib
    libclrinterpreter.dylib
    libSystem.Native.dylib
    libSystem.IO.Compression.Native.dylib
    libSystem.Net.Security.Native.dylib
    libSystem.Security.Cryptography.Native.Apple.dylib
    libSystem.Globalization.Native.dylib
)

FW_WORK="$(mktemp -d)"
FW_ROOT="$FW_WORK/CoreCLR.embeddedframework/CoreCLR.framework"
mkdir -p "$FW_ROOT/Frameworks"

# Main binary: copy libcoreclr.dylib as the framework executable.
cp "$CORECLR_DYLIB" "$FW_ROOT/CoreCLR"
chmod +x "$FW_ROOT/CoreCLR"

# Sub-frameworks: copy the other dylibs into Frameworks/.
for DYLIB in "${OTHER_DYLIBS[@]}"; do
    if [[ -f "$DYLIBS_DIR/$DYLIB" ]]; then
        cp "$DYLIBS_DIR/$DYLIB" "$FW_ROOT/Frameworks/$DYLIB"
    else
        echo "Warning: $DYLIB not found in $DYLIBS_DIR - skipping" >&2
    fi
done

# Info.plist (required for dyld validation).
cat > "$FW_ROOT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CoreCLR</string>
    <key>CFBundleIdentifier</key><string>com.unrealsharp.coreclr</string>
    <key>CFBundleName</key><string>CoreCLR</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>MinimumOSVersion</key><string>15.0</string>
</dict>
</plist>
PLIST

# Pack into .embeddedframework.zip (UE5's expected format).
cd "$FW_WORK"
zip -r --symlinks "$OUTPUT_DIR/CoreCLR.embeddedframework.zip" CoreCLR.embeddedframework > /dev/null
rm -rf "$FW_WORK"

echo ">>> Created: $OUTPUT_DIR/CoreCLR.embeddedframework.zip"
echo "    (libcoreclr.dylib as CoreCLR binary + ${#OTHER_DYLIBS[@]} dylibs in Frameworks/)"
