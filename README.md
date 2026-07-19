# CoreClrSDK for UnrealSharp

CoreCLR runtime SDK for [UnrealSharp](https://github.com/RPG3D/UnrealSharp). This repository contains build scripts, CI workflows, and UBT integration files. Pre-built binaries are distributed via [GitHub Releases](https://github.com/RPG3D/CoreClrSDK/releases).

CoreCLR is the default .NET runtime for UnrealSharp on all platforms: Windows, macOS, Linux, Android, iOS, and iOS Simulator.

## Download (Recommended)

1. Go to [Releases](https://github.com/RPG3D/CoreClrSDK/releases)
2. Download `CoreClrSDK-{version}-{build-type}.zip`
3. Extract to UnrealSharp's `Source/ThirdParty/CoreClrSDK/`

## Build from Source

```bash
# Clone dotnet/runtime (release/10.0 branch)
git clone --depth 1 --branch release/10.0 https://github.com/dotnet/runtime.git ~/dotnet-runtime

# Build for a specific platform
./BuildCoreClrSDK.sh ~/dotnet-runtime <platform> [build-type]

# Platforms: win64 | linux | macos | android | ios | iossimulator | iossimulatorx64
# Build types: Debug (default) | Release

# Example: iOS Simulator Debug
./BuildCoreClrSDK.sh ~/dotnet-runtime iossimulator Debug
# (iossimulator = arm64 sim for Apple Silicon Macs; iossimulatorx64 = x64 sim for Intel Macs.
#  The iOS Simulator arch follows the host CPU - build both if you target both Macs.)
```

Prerequisites: Visual Studio 2022 (Windows), Xcode (macOS/iOS), Android NDK (Android), CMake + Ninja.

## Build Subsets

CoreCLR uses two build subsets (vs Mono's single `mono+libs`):

| Subset | Purpose | Output |
|--------|---------|--------|
| `clr.native` | Native runtime (libcoreclr, libclrjit, libclrinterpreter) | `.so` / `.dylib` / `.dll` |
| `clr.corelib` | Managed System.Private.CoreLib (pure-IL) | `.dll` in `coreclr/*/IL/` |

The pure-IL `System.Private.CoreLib.dll` from `clr.corelib` is critical for iOS — the crossgen'd (ReadyToRun) version from the testhost/runtime-pack lacks `System.__Canon` in a form the interpreter needs.

## Repository Structure

```
├── .github/workflows/        # CI: build-all.yml + package-release.yml
├── BuildCoreClrSDK.sh        # Main build script (dotnet/runtime → SDK)
├── FetchCoreClrSDK.sh/.bat   # Android NuGet download (alternative)
├── FetchCoreClrSDK_iOS.sh    # iOS local build copy (alternative)
├── MakeCoreClrFramework.sh   # iOS framework packager (.embeddedframework.zip)
├── CoreClrSDK.Build.cs       # UnrealBuildTool external module
├── CoreClrSDK_APL.xml        # Android APL manifest
├── include/                  # CoreCLR C headers (coreclrhost.h, host_runtime_contract.h)
└── <platform>/               # Platform binary directories (git-ignored)
    ├── lib/                  # Native runtime files
    └── runtime/              # BCL managed .dll
```

## Platform Directory Layout

Each platform follows the same structure:

```
<platform>/
├── lib/
│   ├── libcoreclr.{so|dylib|dll}        # CoreCLR runtime
│   ├── libclrjit.{so|dylib|dll}          # JIT compiler
│   ├── libclrinterpreter.{so|dylib|dll}  # Interpreter
│   ├── libSystem.Native.{so|dylib}       # System native shims
│   ├── libSystem.IO.Compression.Native.{so|dylib}
│   ├── libSystem.Globalization.Native.{so|dylib}
│   ├── libSystem.Net.Security.Native.{so|dylib}
│   ├── libSystem.Security.Cryptography.Native.Apple.{so|dylib}
│   └── *.embeddedframework.zip           # iOS only: framework packages
└── runtime/
    ├── System.Private.CoreLib.dll         # Pure-IL managed CoreLib
    ├── System.Runtime.dll
    ├── System.Collections.dll
    └── ... (~170 BCL DLLs total)
```

## Integration with UnrealSharp

1. Clone this repo (or download from Releases) to `Source/ThirdParty/CoreClrSDK/` in the UnrealSharp plugin
2. `CoreClrSDK.Build.cs` handles:
   - **Android**: compile-time link `libcoreclr.so`, stage BCL as NonUFS, project DLLs as UFS, APL for `.so` staging
   - **iOS Simulator**: framework `.zip` staging, bare dylib staging, BCL NonUFS, project DLLs UFS
   - **Other platforms**: no-op (hostfxr path handles Win64/Mac/Linux)

## References

- [dotnet/runtime](https://github.com/dotnet/runtime) — .NET runtime source (branch: release/10.0)
- [UnrealSharp](https://github.com/RPG3D/UnrealSharp)
- [IOSClrDemo](https://github.com/RPG3D/CoreClrDemo/tree/main/IOSClrDemo) — iOS CoreCLR demo

## License

MIT.
