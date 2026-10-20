// CoreClrSDK.Build.cs
// UBT External-module wrapper for the mobile CoreCLR runtime SDK.
//
// Only Android and iOS consume this SDK. Desktop platforms (Win64 / Mac / Linux) run
// the upstream hostfxr host and link nothing from here, so this module is a no-op for
// them and the SDK ships no desktop payload.
//
// Responsibilities:
//   Android  link libcoreclr.so at compile time, stage CoreCLR_APL.xml (.so → APK lib/)
//   iOS      link CoreCLR.embeddedframework.zip (device and simulator variants)
//   both     stage the BCL as UFS in Content/Managed/<Platform> so the host reads it
//            from the PAK, and stage the project managed DLLs UFS next to it
//
// SDK directory layout (Source/ThirdParty/CoreClrSDK/), same convention as MonoSDK:
//   include/                          shared CoreCLR C headers (tracked)
//   Android/arm64/{lib,runtime}/      Android device
//   IOS/arm64/{lib,runtime}/          iOS device (+ CoreCLR.embeddedframework.zip)
//   IOSSimulator/arm64/{lib,runtime}/ iOS simulator
//
// The pre-arch-split flat form (<Platform>/{lib,runtime}) is still accepted so an SDK
// extracted from an older release keeps working.

using System;
using System.IO;
using EpicGames.Core;
using Microsoft.Extensions.Logging;
using UnrealBuildTool;

public class CoreClrSDK : ModuleRules
{
    public CoreClrSDK(ReadOnlyTargetRules Target) : base(Target)
    {
        Type = ModuleType.External;

        // ModuleDirectory IS the SDK root (Source/ThirdParty/CoreClrSDK/).
        string SdkRoot = ModuleDirectory;

        // coreclrhost.h / host_runtime_contract.h: the public C host ABI. Shared by all
        // platforms and tracked in git (two stable files), unlike MonoSDK's headers which
        // are a per-build superset.
        string IncludeDir = Path.Combine(SdkRoot, "include");
        if (Directory.Exists(IncludeDir))
        {
            PublicIncludePaths.Add(IncludeDir);
        }

        bool bIsAndroid = Target.Platform == UnrealTargetPlatform.Android;
        bool bIsIOS = Target.Platform == UnrealTargetPlatform.IOS;

        // Desktop: hostfxr path in CGDotNetRuntimeHost, nothing to link or stage.
        if (!bIsAndroid && !bIsIOS)
        {
            return;
        }

        // UBT reports Target.Platform == IOS for both real devices and the simulator;
        // the architecture tells them apart (UnrealArch.IOSSimulator).
        bool bIsSimulator = bIsIOS && Target.Architecture == UnrealArch.IOSSimulator;
        string PlatformName = bIsAndroid ? "Android" : (bIsSimulator ? "IOSSimulator" : "IOS");
        string ArchName = bIsSimulator ? GetIOSSimulatorArchName() : GetArchName(Target.Architecture, PlatformName);
        string SdkPlatformDir = ResolvePlatformDir(SdkRoot, PlatformName, ArchName);

        string NativeLibDir = Path.Combine(SdkPlatformDir, "lib");
        string BclRuntimeDir = Path.Combine(SdkPlatformDir, "runtime");

        // Device and simulator share Content/Managed/IOS: managed IL is arch-independent
        // (PackageProjectMobile publishes to Content/Managed/IOS for both).
        string ContentPlatformDir = bIsAndroid ? "Android" : "IOS";

        // BCL: UFS into the PAK. One layout for both platforms; on iOS it also sidesteps
        // the native path remapping/case-folding that breaks filesystem lookups.
        if (Directory.Exists(BclRuntimeDir))
        {
            foreach (string BclFile in Directory.EnumerateFiles(BclRuntimeDir, "*.dll"))
            {
                string BclDest = $"$(ProjectDir)/Content/Managed/{ContentPlatformDir}/{Path.GetFileName(BclFile)}";
                RuntimeDependencies.Add(BclDest, BclFile, StagedFileType.UFS);
            }
        }

        // Project managed DLLs + LoadOrder.json, published by PackageProjectMobile before
        // UAT runs. UFS keeps them hot-updatable alongside the BCL.
        string ProjectDir = Target.ProjectFile != null
            ? Path.GetDirectoryName(Target.ProjectFile.FullName)!
            : null;
        if (ProjectDir != null)
        {
            string ManagedContentDir = Path.Combine(ProjectDir, "Content", "Managed", ContentPlatformDir);
            if (Directory.Exists(ManagedContentDir))
            {
                RuntimeDependencies.Add(Path.Combine(ManagedContentDir, "*.dll"), StagedFileType.UFS);
                RuntimeDependencies.Add(Path.Combine(ManagedContentDir, "*.pdb"), StagedFileType.UFS);
                RuntimeDependencies.Add(Path.Combine(ManagedContentDir, "*.json"), StagedFileType.UFS);
            }
        }

        if (bIsAndroid)
        {
            string CoreClrLib = Path.Combine(NativeLibDir, "libcoreclr.so");
            if (!File.Exists(CoreClrLib))
            {
                throw new BuildException(
                    $"CoreClrSDK: libcoreclr.so not found at '{CoreClrLib}'.\n" +
                    $"Populate {SdkPlatformDir} from the CoreClrSDK release zip, " +
                    "or run FetchCoreClrSDK.sh / BuildCoreClrSDK.sh android.");
            }

            PublicAdditionalLibraries.Add(CoreClrLib);

            // Copies lib/*.so into APK lib/arm64-v8a/ and loads libcoreclr before libUnreal.
            string AplPath = Path.Combine(ModuleDirectory, "CoreClrSDK_APL.xml");
            AdditionalPropertiesForReceipt.Add("AndroidPlugin", AplPath);
        }
        else
        {
            // iOS rejects scattered dylibs, so the native runtime ships as one umbrella
            // framework (MakeCoreClrFramework.sh). LinkAndCopy links coreclr_* symbols
            // from the framework binary and copies the whole framework into .app/Frameworks/.
            string FrameworkZip = Path.Combine(NativeLibDir, "CoreCLR.embeddedframework.zip");
            if (!File.Exists(FrameworkZip))
            {
                throw new BuildException(
                    $"CoreClrSDK: CoreCLR.embeddedframework.zip not found at '{FrameworkZip}'.\n" +
                    $"Populate {SdkPlatformDir} from the CoreClrSDK release zip, " +
                    $"or run BuildCoreClrSDK.sh {(bIsSimulator ? "iossimulator" : "ios")}.");
            }

            PublicAdditionalFrameworks.Add(new Framework(
                "CoreCLR",
                FrameworkZip,
                Framework.FrameworkMode.LinkAndCopy,
                null));
        }
    }

    // ── SDK directory resolution ────────────────────────────────────────────────
    //
    // Every platform keeps its SDK at <Platform>/<arch>/ (Android/arm64, IOS/arm64,
    // IOSSimulator/arm64) so the same rule covers all of them. A flat <Platform>/ is
    // accepted as a fallback for SDKs extracted from older releases.
    private string ResolvePlatformDir(string SdkRoot, string PlatformName, string ArchName)
    {
        string ArchDir = Path.Combine(SdkRoot, PlatformName, ArchName);
        if (HasSdkPayload(ArchDir))
        {
            return ArchDir;
        }

        string FlatDir = Path.Combine(SdkRoot, PlatformName);
        if (HasSdkPayload(FlatDir))
        {
            Logger.LogWarning("CoreClrSDK: using legacy flat directory {0} (no populated {1}/ subdirectory). " +
                "Rebuild the SDK with BuildCoreClrSDK.sh to get per-arch directories.",
                FlatDir, ArchName);
            return FlatDir;
        }

        throw new BuildException(
            $"CoreClrSDK for {PlatformName} ({ArchName}) not found. Expected '{ArchDir}'.\n" +
            $"Populate Source/ThirdParty/CoreClrSDK/{PlatformName}/{ArchName}/ by downloading the " +
            "CoreClrSDK release zip, by running BuildCoreClrSDK.sh, or by running the " +
            "'Build CoreClrSDK - All Platforms' GitHub workflow and extracting the artifact.");
    }

    /// <summary>
    /// True when the directory holds SDK payload. BuildCoreClrSDK.sh always produces lib/
    /// and runtime/, so requiring one of them distinguishes a real SDK from a directory
    /// that merely exists (the release workflow creates empty dirs before downloading).
    /// </summary>
    private static bool HasSdkPayload(string PlatformDir)
    {
        return Directory.Exists(Path.Combine(PlatformDir, "lib"))
            || Directory.Exists(Path.Combine(PlatformDir, "runtime"));
    }

    private static string GetArchName(UnrealArch Architecture, string PlatformName)
    {
        if (Architecture == UnrealArch.Arm64)
        {
            return "arm64";
        }

        if (Architecture == UnrealArch.X64)
        {
            return "x64";
        }

        throw new BuildException(
            $"CoreClrSDK: no arch mapping for UnrealArch.{Architecture} on {PlatformName}. " +
            "Add the arch to GetArchName() and to the BuildCoreClrSDK.sh matrix.");
    }

    /// <summary>
    /// Architecture name for an iOS Simulator target. UE 5.7 builds the simulator as
    /// arm64 only (UEBuildIOS.cs maps UnrealArch.IOSSimulator to clang "arm64").
    /// </summary>
    private static string GetIOSSimulatorArchName()
    {
        return "arm64";
    }
}
