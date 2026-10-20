# CoreClrSDK for UnrealSharp

CoreCLR runtime SDK for [UnrealSharp](https://github.com/RPG3D/UnrealSharp). This repository
contains build scripts, CI workflows and UBT integration files. Pre-built binaries are
distributed via [GitHub Releases](https://github.com/RPG3D/CoreClrSDK/releases).

**Mobile only.** Android and iOS have no hostfxr, so UnrealSharp bootstraps CoreCLR through
the raw `coreclr_initialize` / `coreclr_create_delegate` C API and needs this SDK. Desktop
(Win64 / macOS / Linux) uses the upstream hostfxr host and links nothing from here, so the
SDK ships no desktop payload — building one would be pure CI time.

## Download (Recommended)

1. Go to [Releases](https://github.com/RPG3D/CoreClrSDK/releases)
2. Download `CoreClrSDK-{version}-{build-type}.zip`
3. Extract into `Plugins/UnrealSharp/Source/ThirdParty/CoreClrSDK/`

## Directory layout

Same convention as [MonoSDK](https://github.com/RPG3D/MonoSDK): every platform keeps its
SDK at `<Platform>/<arch>/`, so one rule covers all of them.

```
Android/arm64/               # Android device
IOS/arm64/                   # iOS device
IOSSimulator/arm64/          # iOS Simulator
    lib/                     # libcoreclr, libclrjit, libclrinterpreter, System.* shims
    runtime/                 # BCL managed assemblies (~170 dlls)
    VERSION.txt              # dotnet/runtime commit + subset list used
    CoreCLR.embeddedframework.zip   # iOS / Simulator only
include/                     # public host ABI headers (tracked, shared by all platforms)
```

iOS rejects scattered dylibs, so all native runtime files are packaged into a single
umbrella framework (`CoreCLR.embeddedframework.zip`) that UBT links and copies into
`.app/Frameworks/`. `System.Private.CoreLib.dll` is always the **pure-IL** copy from
`clr.corelib`: the ReadyToRun build from the runtime pack cannot be used by the
interpreter.

## Build from Source

```bash
# Clone dotnet/runtime at the pinned tag (see DotNetRuntime.version / RUNTIME_TAG)
git clone --depth 1 --branch v11.0.0-rc.1.26425.128 https://github.com/dotnet/runtime.git ~/dotnet-runtime

# Build + populate the SDK directory in one step
./BuildCoreClrSDK.sh ~/dotnet-runtime android       Release arm64
./BuildCoreClrSDK.sh ~/dotnet-runtime ios           Release arm64
./BuildCoreClrSDK.sh ~/dotnet-runtime iossimulator  Release arm64
```

`BuildCoreClrSDK.sh` owns the platform/arch matrix, applies the iOS libs patch, and calls
`CopySDKFromSrc.sh` at the end. `CopySDKFromSrc.sh` can also be run on its own against an
already-built tree (that is what CI does).

Prerequisites: Xcode (iOS / Simulator), Android NDK (Android), CMake + Ninja.

### Fast path (Android only)

```bash
./FetchCoreClrSDK.sh          # NuGet runtime pack -> Android/arm64/{lib,runtime}
```

Downloads `microsoft.netcore.app.runtime.android-arm64` at the pinned version instead of
building the runtime. Valid for Android because the JIT consumes the ReadyToRun CoreLib.
iOS cannot use this path (interpreter needs the pure-IL CoreLib).

## Build subsets (why the build is short)

`DotNetRuntime.version` is the single source of truth (`BUILD_SUBSET`), shared by the build
script and CI. The SDK consumes exactly these outputs:

| Subset | Provides |
|---|---|
| `clr.runtime` | `libcoreclr`, `libclrjit`, `libclrinterpreter` |
| `clr.corelib` | pure-IL `System.Private.CoreLib.dll` |
| `clr.nativecorelib` | R2R CoreLib input for the runtime pack |
| `libs.sfx` | BCL managed assemblies + runtime-pack layout |
| `libs.native` | `System.Native` / Compression / Globalization / Security shims |

Subsets that used to be built and are now deliberately absent:

| Subset | Why it was unnecessary |
|---|---|
| `clr.alljits` | alt-JITs for JIT tests / ILCompiler; the SDK ships one JIT |
| `clr.tools` | ILCompiler, crossgen2 publish, ILVerify, ilasm/ildasm, dotnet-pgo, R2RDump, cdac-build-tool |
| `clr.packages` | NuGet packaging of IL SDK / TestHost / ILAsm — `CoreClrSDK` is not a NuGet package |
| `libs.oob` | out-of-band libraries that are not part of the shared framework |
| `libs.pretest` | test infrastructure and test assets |

`CopySDKFromSrc.sh` fails loudly if a required output is missing, so dropping a subset can
never silently produce an incomplete SDK.

## GitHub Actions

Both workflows are `workflow_dispatch`-only and build on GitHub-hosted macOS runners.

- `build-all.yml` — three flat jobs (`build-android`, `build-ios`, `build-iossimulator`),
  each calling `BuildCoreClrSDK.sh`. Artifacts: `CoreClrSDK-Android-arm64-{Debug,Release}`,
  `CoreClrSDK-iOS-arm64-*`, `CoreClrSDK-iOS-Simulator-arm64-*`.
- `package-release.yml` — downloads the three artifacts into `Android/arm64`,
  `IOS/arm64`, `IOSSimulator/arm64`, verifies payload counts, and publishes one release zip.

## Integration with UnrealSharp

`CoreClrSDK.Build.cs`:

- **Android** — links `lib/coreclr.so`, stages the BCL as **UFS** into
  `Content/Managed/Android`, project DLLs UFS next to it, and wires `CoreClrSDK_APL.xml`
  so `lib/*.so` land in `APK/lib/arm64-v8a/`.
- **iOS device** — links `IOS/arm64/lib/CoreCLR.embeddedframework.zip`; BCL and project
  DLLs are staged UFS into `Content/Managed/IOS` (shared by device and simulator).
- **iOS Simulator** — same, from `IOSSimulator/arm64`.
- **Desktop** — no-op (`hostfxr` path in the plugin).

`<Platform>/<arch>/` is resolved per target architecture; a legacy flat `<Platform>/` is
still accepted for SDKs extracted from older releases.

## Repository Structure

```
├── .github/workflows/        # CI: build-all.yml + package-release.yml
├── BuildCoreClrSDK.sh        # build dotnet/runtime -> SDK (calls CopySDKFromSrc.sh)
├── CopySDKFromSrc.sh         # copy an already-built tree -> SDK (CI entry point)
├── FetchCoreClrSDK.sh/.bat   # Android NuGet fast path
├── MakeCoreClrFramework.sh   # iOS umbrella framework packager
├── DotNetRuntime.version     # pinned TFM/runtime version/BUILD_SUBSET
├── CoreClrSDK.Build.cs       # UnrealBuildTool external module
├── CoreClrSDK_APL.xml        # Android APL manifest
└── include/                  # coreclrhost.h, host_runtime_contract.h
```

## References

- [dotnet/runtime](https://github.com/dotnet/runtime) — runtime source (pinned tag in `DotNetRuntime.version`)
- [UnrealSharp](https://github.com/RPG3D/UnrealSharp)
- [MonoSDK](https://github.com/RPG3D/MonoSDK) — the layout/build conventions this repo follows
- [IOSClrDemo](https://github.com/RPG3D/CoreClrDemo/tree/main/IOSClrDemo) — iOS CoreCLR demo

## License

MIT.
