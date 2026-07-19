// CoreClrSDK.Build.cs
// UBT External-module wrapper for the CoreCLR runtime SDK.
//
// Android is a first-class supported platform (no opt-in switch). On Android this module:
//   • stages BCL managed DLLs as NonUFS (outside PAK, runtime-version-bound)
//   • stages project managed DLLs (*.dll/*.pdb/*.json) from Content/Managed/Android/
//     as UFS (inside PAK, hot-update)
//   • wires CoreClrSDK_APL.xml so native .so land in APK lib/arm64-v8a/
//
// iOS Simulator (added IOSClr branch):
//   • stages CoreCLR dylibs as .embeddedframework.zip files (PublicAdditionalFrameworks)
//   • stages bare system dylibs as NonUFS (for P/Invoke @rpath resolution)
//   • stages BCL DLLs as NonUFS (staged to .app root, matching IOSClrDemo pattern)
//   • stages project DLLs as UFS (inside PAK, Content/Managed/iOSSimulator/)
// On all other platforms it is a no-op (the hostfxr path handles Win64/Mac).
//
// The platform dispatch in CSDotNetRuntimeHost uses a plain #if PLATFORM_ANDROID /
// #elif PLATFORM_IOS (no macro), consistent with how Win64/Mac are handled.
//
// SDK files and this Build.cs live together in Source/ThirdParty/CoreClrSDK/
// (standard UE5 plugin ThirdParty layout).
//
// SDK directory layout (Source/ThirdParty/CoreClrSDK/):
//   Android/lib/        native .so  (libcoreclr.so, libclrjit.so, libSystem.*.so)
//   Android/runtime/    BCL managed .dll
//   iOSSimulator/lib/      native .dylib + .embeddedframework.zip  (arm64 sim)
//   iOSSimulator/runtime/ BCL managed .dll
//   iOSSimulatorX64/lib/   native .dylib + .embeddedframework.zip  (x64 sim)
//   iOSSimulatorX64/runtime/ BCL managed .dll
//   include/            coreclrhost.h, host_runtime_contract.h
// CoreClrSDK_APL.xml lives alongside this file.
// iOS Simulator arch is selected by the host Mac CPU (see platformDir below):
// iOSSimulator on Apple Silicon (arm64), iOSSimulatorX64 on Intel (x64).

using System.IO;
using System.Runtime.InteropServices;
using UnrealBuildTool;

public class CoreClrSDK : ModuleRules
{
    public CoreClrSDK(ReadOnlyTargetRules Target) : base(Target)
    {
        Type = ModuleType.External;

        // ModuleDirectory IS the SDK root (Source/ThirdParty/CoreClrSDK/).
        string sdkRoot = ModuleDirectory;

        // Expose coreclrhost.h + host_runtime_contract.h so the host can include them.
        string includeDir = Path.Combine(sdkRoot, "include");
        if (Directory.Exists(includeDir))
        {
            PublicIncludePaths.Add(includeDir);
        }

        // ── Android ─────────────────────────────────────────────────────────
        if (Target.Platform == UnrealTargetPlatform.Android)
        {
            string nativeLibDir = Path.Combine(sdkRoot, "Android", "lib");
            string bclRuntimeDir = Path.Combine(sdkRoot, "Android", "runtime");

            // Compile-time link against libcoreclr.so (NDK linker -l).
            // libcoreclr.so is staged into APK lib/arm64-v8a/ by CoreClrSDK_APL.xml
            // so the OS linker resolves it at load time.
            string coreclrLibPath = Path.Combine(nativeLibDir, "libcoreclr.so");
            if (File.Exists(coreclrLibPath))
            {
                PublicAdditionalLibraries.Add(coreclrLibPath);
            }

            // BCL managed DLLs — staged as NonUFS (outside PAK).
            if (Directory.Exists(bclRuntimeDir))
            {
                RuntimeDependencies.Add(Path.Combine(bclRuntimeDir, "...*.dll"), StagedFileType.NonUFS);
            }

            // APL for .so staging into APK lib/arm64-v8a/.
            string aplPath = Path.Combine(ModuleDirectory, "CoreClrSDK_APL.xml");
            if (File.Exists(aplPath))
            {
                AdditionalPropertiesForReceipt.Add("AndroidPlugin", aplPath);
            }

            // Project managed DLLs — staged UFS (inside PAK).
            if (Target.ProjectFile != null)
            {
                string projectDir = Path.GetDirectoryName(Target.ProjectFile.FullName)!;
                string managedContentDir = Path.Combine(projectDir, "Content", "Managed", "Android");
                if (Directory.Exists(managedContentDir))
                {
                    RuntimeDependencies.Add(Path.Combine(managedContentDir, "*.dll"), StagedFileType.UFS);
                    RuntimeDependencies.Add(Path.Combine(managedContentDir, "*.pdb"), StagedFileType.UFS);
                    RuntimeDependencies.Add(Path.Combine(managedContentDir, "*.json"), StagedFileType.UFS);
                }
            }
        }
        // ── iOS / iOS Simulator ──────────────────────────────────────────────
        else if (Target.Platform == UnrealTargetPlatform.IOS)
        {
            // UBT uses Target.Platform == IOS for BOTH real device and Simulator.
            // Architecture distinguishes: UnrealArch.IOSSimulator vs UnrealArch.Arm64.
            // Currently only iOS Simulator is supported (device is future work).
            bool bIsSimulator = (Target.Architecture == UnrealArch.IOSSimulator);

            // iOS Simulator arch follows the host Mac CPU: the iOS Simulator itself
            // runs arm64 on Apple Silicon and x64 on Intel, so the CoreCLR sim
            // runtime must match the host. Mirrors dotnet's -arch default and the
            // two CI jobs (iossimulator -> arm64, iossimulatorx64 -> x64).
            // NOTE: an Apple Silicon Mac running an x64 simulator via Rosetta 2 is
            // not auto-detected; rename the dir or override locally if you need that.
            string simulatorDir = (RuntimeInformation.ProcessArchitecture == Architecture.Arm64)
                ? "iOSSimulator" : "iOSSimulatorX64";
            string platformDir = bIsSimulator ? simulatorDir : "IOS";
            string nativeLibDir = Path.Combine(sdkRoot, platformDir, "lib");
            string bclRuntimeDir = Path.Combine(sdkRoot, platformDir, "runtime");

            // ── Framework staging: .embeddedframework.zip → IPA Frameworks/ ──
            // Each CoreCLR dylib is packaged as its own .embeddedframework.zip
            // (matching IOSClrDemo's one-framework-per-dylib pattern).
            //
            // NOTE: We do NOT use PublicAdditionalFrameworks because UBT on iOS
            // may interpret Copy mode as Link, adding LC_LOAD_DYLIB to the binary.
            // Instead we use dlopen at runtime. The framework zips are staged as
            // NonUFS RuntimeDependencies — they'll be extracted and copied to the
            // IPA bundle at packaging time.

            // CoreCLR runtime frameworks (loaded via dlopen at runtime, NOT linked):
            string[] coreclrFrameworks = {
                "libcoreclr",
                "libclrjit",
                "libclrinterpreter",
            };

            // System native shim frameworks (loaded by CoreCLR P/Invoke at runtime).
            // These ALSO need bare dylib copies (see below) because CoreCLR's
            // P/Invoke resolver looks for @rpath/libSystem.Native.dylib, not the
            // framework path.
            string[] systemFrameworks = {
                "libSystem.Native",
                "libSystem.IO.Compression.Native",
                "libSystem.Globalization.Native",
                "libSystem.Net.Security.Native",
                "libSystem.Security.Cryptography.Native.Apple",
            };

            // Stage all framework zips as NonUFS RuntimeDependencies (NOT linked).
            foreach (string fwName in coreclrFrameworks)
            {
                string fwZipPath = Path.Combine(nativeLibDir, fwName + ".embeddedframework.zip");
                if (File.Exists(fwZipPath))
                {
                    RuntimeDependencies.Add(fwZipPath, StagedFileType.NonUFS);
                }
            }
            foreach (string fwName in systemFrameworks)
            {
                string fwZipPath = Path.Combine(nativeLibDir, fwName + ".embeddedframework.zip");
                if (File.Exists(fwZipPath))
                {
                    RuntimeDependencies.Add(fwZipPath, StagedFileType.NonUFS);
                }
            }

            // ── Bare system dylib staging (for P/Invoke @rpath resolution) ──
            // CoreCLR's P/Invoke resolver and corhost.cpp preload resolve
            // "libSystem.Native" → "@rpath/libSystem.Native.dylib", which does
            // NOT match the .framework wrapper path. Without bare copies at a
            // @rpath/@executable_path location, CoreCLR fails with
            // DllNotFoundException. This matches the IOSClrDemo pattern
            // (bare copies to both .app root and .app/Frameworks).
            foreach (string fwName in systemFrameworks)
            {
                string dylibPath = Path.Combine(nativeLibDir, fwName + ".dylib");
                if (File.Exists(dylibPath))
                {
                    // Stage bare dylib to .app root (for @executable_path resolution)
                    RuntimeDependencies.Add(dylibPath, StagedFileType.NonUFS);
                }
            }

            // ── BCL managed DLLs — staged as NonUFS (to .app root) ──────────
            // Matching IOSClrDemo: BCL DLLs go in .app bundle root, loaded via
            // APP_CONTEXT_BASE_DIRECTORY + TPA. CoreCLR reads them directly
            // from the bundle filesystem.
            if (Directory.Exists(bclRuntimeDir))
            {
                RuntimeDependencies.Add(Path.Combine(bclRuntimeDir, "...*.dll"), StagedFileType.NonUFS);
            }

            // ── Project managed DLLs — staged UFS (inside PAK) ──────────────
            // Content/Managed/iOSSimulator/ → inside PAK, hot-updatable.
            if (Target.ProjectFile != null)
            {
                string projectDir = Path.GetDirectoryName(Target.ProjectFile.FullName)!;
                // Project DLLs are arch-neutral IL, so ONE iOSSimulator/ dir serves
                // both arm64-sim and x64-sim (do NOT split by simulatorDir).
                string managedPlatformDir = bIsSimulator ? "iOSSimulator" : "IOS";
                string managedContentDir = Path.Combine(projectDir, "Content", "Managed", managedPlatformDir);
                if (Directory.Exists(managedContentDir))
                {
                    RuntimeDependencies.Add(Path.Combine(managedContentDir, "*.dll"), StagedFileType.UFS);
                    RuntimeDependencies.Add(Path.Combine(managedContentDir, "*.pdb"), StagedFileType.UFS);
                    RuntimeDependencies.Add(Path.Combine(managedContentDir, "*.json"), StagedFileType.UFS);
                }
            }

            // ── iOS system framework dependencies ───────────────────────────
            // CoreCLR requires these Apple frameworks at init time.
            // Matching IOSClrDemo's CMakeLists.txt system framework links.
            // Note: UE5 likely already links Foundation/UIKit/CoreGraphics;
            // these are added for safety and will be no-ops if already present.
            PublicSystemLibraries.Add("z");              // -lz
            PublicSystemLibraries.Add("c++");            // -lc++
            PublicSystemLibraries.Add("iconv");          // -liconv
            PublicSystemLibraries.Add("icucore");        // -licucore (ICU)
        }
    }
}
