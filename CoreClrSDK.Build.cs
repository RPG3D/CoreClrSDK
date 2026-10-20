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
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
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

            // Real device only: UE signs the outer app and the framework bundle, but it
            // does not recurse into CoreCLR.framework/Frameworks/, leaving the nested
            // dylibs unsigned and the on-device install invalid. Pre-sign them here.
            if (!bIsSimulator)
            {
                SignEmbeddedFrameworkZip(NativeLibDir);
            }

            PublicAdditionalFrameworks.Add(new Framework(
                "CoreCLR",
                FrameworkZip,
                Framework.FrameworkMode.LinkAndCopy,
                null));
        }
    }

    // ── Embedded framework pre-signing (iOS device, macOS host only) ────────────
    //
    // Mirrors MonoSDK.Build.cs. UE stages CoreCLR.embeddedframework.zip into the IPA
    // and signs the outer app and the framework binary, but NOT the dylibs nested in
    // CoreCLR.framework/Frameworks/ — pre-sign them so on-device validation passes.
    //
    // Cache: .framework_sign_cache.txt next to the zip, one line per signed zip:
    //   "<zip sha256> <identity sha1>"
    // The identity is part of the key on purpose: the signature is bound to the
    // certificate, so a renewed/rotated certificate, a different team's profile, or a
    // switch between manual and automatic signing must re-sign even though the zip
    // bytes are unchanged. A plain content hash (MonoSDK's original scheme) would
    // silently keep the stale signature and the install would fail at launch.
    private void SignEmbeddedFrameworkZip(string nativeLibDir)
    {
        if (!OperatingSystem.IsMacOS())
        {
            return;
        }

        string ZipPath = Path.Combine(nativeLibDir, "CoreCLR.embeddedframework.zip");
        if (!File.Exists(ZipPath))
        {
            return;
        }

        string CachePath = Path.Combine(nativeLibDir, ".framework_sign_cache.txt");
        try
        {
            string Identity = FindCodeSigningIdentity();
            if (Identity == null)
            {
                Logger.LogWarning("CoreClrSDK: no code-signing identity found; nested framework dylibs are unsigned.");
                return;
            }

            string ZipHash = ComputeSha256(ZipPath);
            if (IsInSignCache(CachePath, ZipHash, Identity))
            {
                Logger.LogInformation("CoreClrSDK: CoreCLR.embeddedframework.zip already signed with {0}; skipping.", Identity);
                return;
            }

            // Unzip -> codesign every Mach-O -> repack with native zip (keeps unix
            // modes and symlinks; ZipArchive would flatten both).
            string WorkDir = Path.Combine(Path.GetTempPath(), "CoreClrSDKSign_" + Path.GetRandomFileName());
            string ExtractDir = Path.Combine(WorkDir, "extract");
            Directory.CreateDirectory(ExtractDir);
            File.Copy(ZipPath, ZipPath + ".bak", overwrite: true);
            try
            {
                RunProcessCapture("/usr/bin/unzip", new[] { "-q", ZipPath, "-d", ExtractDir }, checkExit: true);

                string FrameworkRoot = Path.Combine(ExtractDir, "CoreCLR.embeddedframework", "CoreCLR.framework");

                string NestedDir = Path.Combine(FrameworkRoot, "Frameworks");
                if (Directory.Exists(NestedDir))
                {
                    foreach (string Dylib in Directory.EnumerateFiles(NestedDir, "*.dylib", SearchOption.TopDirectoryOnly))
                    {
                        RunProcessCapture("/usr/bin/codesign",
                            new[] { "-f", "-s", Identity, "--timestamp=none", Dylib }, checkExit: true);
                    }
                }

                // The framework binary is signed by Xcode later; pre-signing it keeps the
                // bundle self-consistent for consumers that embed the zip directly.
                string FrameworkBinary = Path.Combine(FrameworkRoot, "CoreCLR");
                if (File.Exists(FrameworkBinary))
                {
                    RunProcessCapture("/usr/bin/codesign",
                        new[] { "-f", "-s", Identity, "--timestamp=none", FrameworkBinary }, checkExit: true);
                }

                string NewZip = Path.Combine(WorkDir, "CoreCLR.embeddedframework.zip");
                RunProcessCapture("/usr/bin/zip", new[] { "-X", "-y", "-q", "-r", NewZip, "CoreCLR.embeddedframework" },
                    ExtractDir, checkExit: true);
                File.Copy(NewZip, ZipPath, overwrite: true);
            }
            finally
            {
                Directory.Delete(WorkDir, true);
            }

            AppendToSignCache(CachePath, ZipHash, Identity);
            Logger.LogInformation("CoreClrSDK: CoreCLR.embeddedframework.zip signed with {0}; pristine original kept at {1}.bak.",
                Identity, ZipPath);
        }
        catch (Exception Ex)
        {
            Logger.LogWarning("CoreClrSDK: framework signing skipped due to error: {0}", Ex.Message);
        }
    }

    /// <summary>
    /// SHA-1 of the preferred code-signing identity, or null when none is usable.
    /// When Config/IOS/IOSEngine.ini declares CodeSigningTeam, an identity carrying that
    /// team in its display name wins; otherwise the first valid identity is used.
    /// The SHA-1 (not the name) is returned so codesign cannot resolve to a revoked or
    /// duplicate-name certificate. CSSMERR_ lines are expired/revoked and are skipped.
    /// </summary>
    private string FindCodeSigningIdentity()
    {
        (_, string StdOut) = RunProcessCapture("/usr/bin/security", new[] { "find-identity", "-v", "-p", "codesigning" });

        string PreferredTeam = GetConfiguredSigningTeam();
        string FirstIdentity = null;

        foreach (string Line in StdOut.Split('\n'))
        {
            if (Line.Contains("CSSMERR_", StringComparison.Ordinal))
            {
                continue;
            }

            string[] Parts = Line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (Parts.Length < 2 || Parts[1].Length != 40 || !IsHexString(Parts[1]))
            {
                continue;
            }

            FirstIdentity ??= Parts[1];
            if (!string.IsNullOrEmpty(PreferredTeam) &&
                Line.Contains("(" + PreferredTeam + ")", StringComparison.OrdinalIgnoreCase))
            {
                return Parts[1];
            }
        }

        return FirstIdentity;
    }

    /// <summary>
    /// CodeSigningTeam from Config/IOS/IOSEngine.ini, or null when the file/key is absent.
    /// Read as plain text: the ini layers UBT sees in a module rule do not include the
    /// platform-specific Xcode signing section.
    /// </summary>
    private string GetConfiguredSigningTeam()
    {
        if (Target.ProjectFile == null)
        {
            return null;
        }

        string ProjectDir = Path.GetDirectoryName(Target.ProjectFile.FullName);
        string IniPath = Path.Combine(ProjectDir, "Config", "IOS", "IOSEngine.ini");
        if (!File.Exists(IniPath))
        {
            return null;
        }

        foreach (string Line in File.ReadAllLines(IniPath))
        {
            string Trimmed = Line.Trim();
            if (!Trimmed.StartsWith("CodeSigningTeam", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            int EqualsIndex = Trimmed.IndexOf('=');
            if (EqualsIndex >= 0)
            {
                string Team = Trimmed.Substring(EqualsIndex + 1).Trim();
                if (Team.Length > 0)
                {
                    return Team;
                }
            }
        }

        return null;
    }

    private string ComputeSha256(string Path)
    {
        return Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(Path))).ToLowerInvariant();
    }

    /// <summary>
    /// True when every character is an ASCII hex digit. Inlined rather than
    /// Uri.IsHexDigit: System.Uri is not in the assembly set UBT references when
    /// compiling rules, so it fails to resolve on macOS.
    /// </summary>
    private static bool IsHexString(string Value)
    {
        foreach (char C in Value)
        {
            bool bIsHexDigit = (C >= '0' && C <= '9') || (C >= 'a' && C <= 'f') || (C >= 'A' && C <= 'F');
            if (!bIsHexDigit)
            {
                return false;
            }
        }

        return Value.Length > 0;
    }

    private bool IsInSignCache(string CachePath, string ZipHash, string Identity)
    {
        if (!File.Exists(CachePath))
        {
            return false;
        }

        string Expected = ZipHash + " " + Identity;
        return File.ReadAllLines(CachePath).Any(Line => Line.Trim().Equals(Expected, StringComparison.OrdinalIgnoreCase));
    }

    private void AppendToSignCache(string CachePath, string ZipHash, string Identity)
    {
        const int MaxCacheLines = 64;
        List<string> Lines = File.Exists(CachePath)
            ? File.ReadAllLines(CachePath).ToList()
            : new List<string>();

        Lines.Add(ZipHash + " " + Identity);
        if (Lines.Count > MaxCacheLines)
        {
            Lines.RemoveRange(0, Lines.Count - MaxCacheLines);
        }

        File.WriteAllLines(CachePath, Lines);
    }

    private (int ExitCode, string StdOut) RunProcessCapture(string Exe, string[] Args, string WorkingDir = null,
        bool checkExit = false)
    {
        using Process Proc = new();
        Proc.StartInfo.FileName = Exe;
        Proc.StartInfo.UseShellExecute = false;
        Proc.StartInfo.CreateNoWindow = true;
        Proc.StartInfo.RedirectStandardOutput = true;
        Proc.StartInfo.RedirectStandardError = true;
        Proc.StartInfo.WorkingDirectory = WorkingDir ?? Path.GetTempPath();
        foreach (string Arg in Args)
        {
            Proc.StartInfo.ArgumentList.Add(Arg);
        }

        Proc.Start();
        string StdOut = Proc.StandardOutput.ReadToEnd();
        Proc.WaitForExit();
        string StdErr = Proc.StandardError.ReadToEnd();
        if (checkExit && Proc.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"{Exe} failed (exit {Proc.ExitCode}): {(StdErr + StdOut).Trim()}");
        }

        return (Proc.ExitCode, StdOut);
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
