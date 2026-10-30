// CoreClrSDK.Build.cs
// UBT External-module wrapper for the Android CoreCLR runtime SDK.
//
// Android is a first-class supported platform (no opt-in switch). On Android this module:
//   • stages BCL managed DLLs as NonUFS (outside PAK, runtime-version-bound)
//   • stages project managed DLLs (*.dll/*.pdb/*.json) from Content/Managed/Android/
//     as UFS (inside PAK, hot-update)
//   • wires CoreClrSDK_APL.xml so native .so land in APK lib/arm64-v8a/
// On all other platforms it is a no-op (the hostfxr path handles Win64/Mac).
//
// The platform dispatch in CSDotNetRuntimeHost uses a plain #if PLATFORM_ANDROID
// (no macro), consistent with how Win64/Mac are handled.
//
// SDK files and this Build.cs live together in Source/ThirdParty/CoreClrSDK/
// (standard UE5 plugin ThirdParty layout).
//
// SDK directory layout (Source/ThirdParty/CoreClrSDK/):
//   Android/lib/      native .so  (libcoreclr.so, libclrjit.so, libSystem.*.so)
//   Android/runtime/  BCL managed .dll
// CoreClrSDK_APL.xml lives alongside this file.

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
    // ModuleDirectory IS the SDK root (Source/ThirdParty/CoreClrSDK/).
    private readonly string sdkRoot;

    public CoreClrSDK(ReadOnlyTargetRules Target) : base(Target)
    {
        Type = ModuleType.External;

        sdkRoot = ModuleDirectory;

        // Expose coreclrhost.h (raw CoreCLR C API) so the host can include it.
        string includeDir = Path.Combine(sdkRoot, "include");
        if (Directory.Exists(includeDir))
        {
            PublicIncludePaths.Add(includeDir);
        }

        // Backend gate: CoreCLR-on-mobile is active only when the resolved runtime backend
        // for this target is CoreCLR. Android/iOS default to Mono in this branch (see
        // UnrealSharpRuntimeSelection in MonoSDK.Build.cs; `DotNetRuntime=CoreCLR` in the
        // platform ini switches). Without this gate both modules would stage a BCL into
        // Content/Managed/<Platform> and link both runtimes into the binary.
        bool bMobileCoreClr =
            (Target.Platform == UnrealTargetPlatform.Android || Target.Platform == UnrealTargetPlatform.IOS)
            && !UnrealSharpRuntimeSelection.ShouldUseMono(Target);

        if (bMobileCoreClr)
        {
            // SDK payload layout is <Platform>/<arch>/ (same convention as MonoSDK).
            // Android is arm64-only; iOS device is arm64-only, simulator rides its own dir.
            string bclSdkDir = Target.Platform == UnrealTargetPlatform.Android
                ? "Android/arm64"
                : (Target.Architecture == UnrealArch.IOSSimulator ? "IOSSimulator/arm64" : "IOS/arm64");

            string contentPakDir = Target.Platform == UnrealTargetPlatform.Android
                ? "Android"
                : "IOS";
                
            string bclRuntimeDir = Path.Combine(sdkRoot, bclSdkDir, "runtime");
            string contentPlatformKey = Target.Platform == UnrealTargetPlatform.Android ? "ANDROID" : "IOS";
            VerifyPayloadRuntimeMajor(Path.Combine(sdkRoot, bclSdkDir), contentPlatformKey);

            if (Directory.Exists(bclRuntimeDir))
            {
                foreach (string bclDll in Directory.GetFiles(bclRuntimeDir, "*.dll"))
                {
                    RuntimeDependencies.Add(
                        $"$(ProjectDir)/Content/Managed/{contentPakDir}/{Path.GetFileName(bclDll)}",
                        bclDll,
                        StagedFileType.UFS);
                }
            }

            // Project managed DLLs + LoadOrder.json - placed into Content/Managed/<Platform>/
            // by PackageProjectMobile; stage them UFS (inside PAK, hot-updatable). Same dir
            // as BCL (unified PAK layout) but different source files, so no overlap.
            string projectDir = Target.ProjectFile != null
                ? Path.GetDirectoryName(Target.ProjectFile.FullName)!
                : null;
            if (projectDir != null)
            {
                string managedContentDir = Path.Combine(projectDir, "Content", "Managed", contentPakDir);
                if (Directory.Exists(managedContentDir))
                {
                    RuntimeDependencies.Add(Path.Combine(managedContentDir, "*.dll"), StagedFileType.UFS);
                    RuntimeDependencies.Add(Path.Combine(managedContentDir, "*.pdb"), StagedFileType.UFS);
                    RuntimeDependencies.Add(Path.Combine(managedContentDir, "*.json"), StagedFileType.UFS);
                }
            }
        }

        if (bMobileCoreClr && Target.Platform == UnrealTargetPlatform.Android)
        {
            string nativeLibDir = Path.Combine(sdkRoot, "Android", "arm64", "lib");

            string coreclrLibPath = Path.Combine(nativeLibDir, "libcoreclr.so");
            if (File.Exists(coreclrLibPath))
            {
                PublicAdditionalLibraries.Add(coreclrLibPath);
            }

            string aplPath = Path.Combine(ModuleDirectory, "CoreClrSDK_APL.xml");
            if (File.Exists(aplPath))
            {
                AdditionalPropertiesForReceipt.Add("AndroidPlugin", aplPath);
            }
        }

        if (bMobileCoreClr && Target.Platform == UnrealTargetPlatform.IOS)
        {
            bool bIsSimulator = Target.Architecture == UnrealArch.IOSSimulator;
            string platformDir = bIsSimulator ? "IOSSimulator/arm64" : "IOS/arm64";
            string nativeLibDir = Path.Combine(sdkRoot, platformDir, "lib");

            // iOS requires dynamic libraries in an embedded framework (scatter dylibs
            // in .app root is rejected by App Store / fails device install). All CoreCLR
            // native dylibs are packaged into a single CoreCLR.embeddedframework.zip by
            // MakeCoreClrFramework.sh. LinkAndCopy links coreclr_* symbols from the
            // framework binary and copies the whole framework into .app/Frameworks/.
            string frameworkZip = Path.Combine(nativeLibDir, "CoreCLR.embeddedframework.zip");
            if (!File.Exists(frameworkZip))
            {
                throw new BuildException(
                    $"CoreCLR.embeddedframework.zip not found at {frameworkZip}. " +
                    "Run MakeCoreClrFramework.sh to build the single iOS framework.");
            }

            // UE signs the outer app and the framework bundle, but never recurses into
            // CoreCLR.framework/{Frameworks,libclrjit,libclrinterpreter}. An unsigned dylib
            // cannot be dlopen'ed on device (EPERM), and the failure surfaces far away: the
            // first P/Invoke (libSystem.Native during SR message formatting) throws
            // DllNotFoundException, whose message lookup re-enters globalization and ends in
            // FailFast. Pre-sign the nested Mach-O files here, before UE seals the framework.
            SignEmbeddedFrameworkZip(nativeLibDir);

            PublicAdditionalFrameworks.Add(new Framework(
                "CoreCLR",
                frameworkZip,
                Framework.FrameworkMode.LinkAndCopy,
                null));
        }
    }

    // ── Payload / version-file agreement ───────────────────────────────────────
    //
    // The runtime branch follows the backend: Mono -> dotnet 10, CoreCLR -> dotnet 11
    // (11 dropped Mono from the coreclr tree; 10's iOS CoreCLR has no interpreter).
    // DotNetRuntime.version holds the expected major per platform, and CopySDKFromSrc.sh
    // stamps the payload's VERSION.txt with "Runtime: <major>.<version> (<tfm>)". A payload
    // copied from the wrong branch links fine and only fails on device, so compare here.
    private void VerifyPayloadRuntimeMajor(string payloadDir, string platformKey)
    {
        string versionFilePath = Path.Combine(sdkRoot, "DotNetRuntime.version");
        if (!File.Exists(versionFilePath))
            return;

        string expected = ReadVersionKey(versionFilePath, "DOTNET_MAJOR", platformKey);
        if (string.IsNullOrEmpty(expected))
            return;

        string payloadVersionFile = Path.Combine(payloadDir, "VERSION.txt");
        if (!File.Exists(payloadVersionFile))
        {
            Logger.LogWarning("CoreClrSDK: {0} has no VERSION.txt; cannot confirm it is dotnet {1}.",
                payloadDir, expected);
            return;
        }

        string actual = null;
        foreach (string line in File.ReadAllLines(payloadVersionFile))
        {
            const string Prefix = "Runtime: ";
            if (!line.StartsWith(Prefix, StringComparison.Ordinal))
                continue;
            string value = line.Substring(Prefix.Length).Trim();
            int dot = value.IndexOf('.');
            actual = dot > 0 ? value.Substring(0, dot) : value;
            break;
        }

        if (actual == null)
        {
            Logger.LogWarning("CoreClrSDK: {0}/VERSION.txt predates the Runtime stamp; expected dotnet {1}.",
                payloadDir, expected);
            return;
        }

        if (actual != expected)
        {
            throw new BuildException(
                $"CoreCLR payload {payloadDir} is dotnet {actual}, but DotNetRuntime.version pins " +
                $"{platformKey} to dotnet {expected}. Regenerate the payload from the matching " +
                "dotnet/runtime worktree (CopySDKFromSrc.sh) or fix the version file.");
        }
    }

    private static string ReadVersionKey(string versionFilePath, string key, string platformKey)
    {
        string platformValue = null;
        string defaultValue = null;
        foreach (string rawLine in File.ReadAllLines(versionFilePath))
        {
            string line = rawLine.Trim();
            if (line.Length == 0 || line[0] == '#')
                continue;

            if (line.StartsWith(key + "_" + platformKey + "=", StringComparison.Ordinal))
                platformValue = line.Substring((key + "_" + platformKey + "=").Length).Trim();
            else if (line.StartsWith(key + "=", StringComparison.Ordinal))
                defaultValue = line.Substring((key + "=").Length).Trim();
        }

        return platformValue ?? defaultValue;
    }

    // ── Embedded framework pre-signing (real iOS device, macOS host only) ──────
    //
    // Same mechanism as MonoSDK.Build.cs: unzip -> codesign every Mach-O -> repack with
    // the native zip (keeps unix modes and symlinks). The skip cache next to the zip stores
    // "<zip sha256> <identity sha1>": the identity is part of the key on purpose, so a
    // renewed certificate, a different team or a manual<->automatic switch re-signs instead
    // of reusing a signature made by the old certificate. A re-fetched SDK changes the
    // content hash and re-triggers signing too. Any failure logs a warning and lets the
    // build continue.
    private void SignEmbeddedFrameworkZip(string nativeLibDir)
    {
        if (!OperatingSystem.IsMacOS())
            return;

        string zipPath = Path.Combine(nativeLibDir, "CoreCLR.embeddedframework.zip");
        string cachePath = Path.Combine(nativeLibDir, ".framework_sign_cache.txt");
        try
        {
            string identity = FindCodeSigningIdentity(GetConfiguredSigningTeam());
            if (identity == null)
            {
                Logger.LogWarning("CoreClrSDK: no code-signing identity found; framework signing skipped.");
                return;
            }

            if (IsInSignCache(cachePath, ComputeSha256(zipPath), identity))
            {
                Logger.LogInformation("CoreClrSDK: CoreCLR.embeddedframework.zip already signed; skipping.");
                return;
            }

            string workDir = Path.Combine(Path.GetTempPath(), "CoreClrSDKSign_" + Path.GetRandomFileName());
            string extractDir = Path.Combine(workDir, "extract");
            Directory.CreateDirectory(extractDir);
            File.Copy(zipPath, zipPath + ".bak", overwrite: true); // pristine original
            try
            {
                RunProcessCapture("/usr/bin/unzip", new[] { "-q", zipPath, "-d", extractDir }, checkExit: true);

                string fwRoot = Path.Combine(extractDir, "CoreCLR.embeddedframework", "CoreCLR.framework");
                foreach (string dylib in Directory.EnumerateFiles(Path.Combine(fwRoot, "Frameworks"), "*.dylib",
                    SearchOption.TopDirectoryOnly))
                {
                    RunProcessCapture("/usr/bin/codesign",
                        new[] { "-f", "-s", identity, "--timestamp=none", dylib }, checkExit: true);
                }

                // JIT and interpreter engines are dlopen'ed from the framework root.
                foreach (string engine in new[] { "libclrjit.dylib", "libclrinterpreter.dylib" })
                {
                    string enginePath = Path.Combine(fwRoot, engine);
                    if (File.Exists(enginePath))
                    {
                        RunProcessCapture("/usr/bin/codesign",
                            new[] { "-f", "-s", identity, "--timestamp=none", enginePath }, checkExit: true);
                    }
                }

                string frameworkBinary = Path.Combine(fwRoot, "CoreCLR");
                if (File.Exists(frameworkBinary))
                {
                    RunProcessCapture("/usr/bin/codesign",
                        new[] { "-f", "-s", identity, "--timestamp=none", frameworkBinary }, checkExit: true);
                }

                string newZip = Path.Combine(workDir, "CoreCLR.embeddedframework.zip");
                RunProcessCapture("/usr/bin/zip", new[] { "-X", "-y", "-q", "-r", newZip, "CoreCLR.embeddedframework" },
                    extractDir, checkExit: true);
                File.Copy(newZip, zipPath, overwrite: true);
            }
            finally
            {
                Directory.Delete(workDir, true);
            }

            AppendToSignCache(cachePath, ComputeSha256(zipPath), identity);
            Logger.LogInformation("CoreClrSDK: CoreCLR.embeddedframework.zip signed; pristine original kept at {0}.bak.",
                zipPath);
        }
        catch (Exception ex)
        {
            Logger.LogWarning("CoreClrSDK: framework signing skipped due to error: {0}", ex.Message);
        }
    }

    /// <summary>
    /// Team identifier from Config/IOS/IOSEngine.ini (CodeSigningTeam), or null. Signing the
    /// nested dylibs with a certificate from another team would make the framework's Team ID
    /// disagree with the app's and dlopen still fails, so the configured team is preferred.
    /// </summary>
    private string GetConfiguredSigningTeam()
    {
        if (Target.ProjectFile == null)
            return null;

        string iniPath = Path.Combine(Target.ProjectFile.Directory.FullName, "Config", "IOS", "IOSEngine.ini");
        if (!File.Exists(iniPath))
            return null;

        foreach (string line in File.ReadAllLines(iniPath))
        {
            string trimmed = line.Trim();
            if (!trimmed.StartsWith("CodeSigningTeam=", StringComparison.Ordinal))
                continue;
            string team = trimmed.Substring("CodeSigningTeam=".Length).Trim();
            if (team.Length > 0)
                return team;
        }

        return null;
    }

    /// <summary>
    /// SHA-1 of a valid code-signing identity from the keychain, or null. The hash (not the
    /// display name) pins one certificate instance so codesign never resolves to a revoked
    /// or duplicate-name cert. When a team is configured, an identity whose display name
    /// carries that team is preferred; otherwise the first valid identity wins.
    /// </summary>
    private string FindCodeSigningIdentity(string preferredTeam)
    {
        (_, string stdout) =
            RunProcessCapture("/usr/bin/security", new[] { "find-identity", "-v", "-p", "codesigning" });

        string fallback = null;
        foreach (string line in stdout.Split('\n'))
        {
            if (line.Contains("CSSMERR_", StringComparison.Ordinal))
                continue;
            string[] parts = line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2 || parts[1].Length != 40 || !IsHexString(parts[1]))
                continue;

            if (preferredTeam != null && line.Contains(preferredTeam, StringComparison.Ordinal))
                return parts[1];

            fallback ??= parts[1];
        }

        return fallback;
    }

    private static bool IsHexString(string value)
    {
        foreach (char c in value)
        {
            bool bIsHexDigit = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
            if (!bIsHexDigit)
                return false;
        }

        return value.Length > 0;
    }

    private string ComputeSha256(string path)
    {
        return Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant();
    }

    private bool IsInSignCache(string cachePath, string hash, string identity)
    {
        if (!File.Exists(cachePath))
            return false;

        string expected = hash + " " + identity;
        return File.ReadAllLines(cachePath).Any(line => line.StartsWith(expected, StringComparison.OrdinalIgnoreCase));
    }

    private void AppendToSignCache(string cachePath, string hash, string identity)
    {
        const int MaxCacheLines = 64;
        List<string> lines = File.Exists(cachePath)
            ? File.ReadAllLines(cachePath).ToList()
            : new List<string>();
        lines.Add(hash + " " + identity);
        if (lines.Count > MaxCacheLines)
            lines.RemoveRange(0, lines.Count - MaxCacheLines);

        File.WriteAllLines(cachePath, lines);
    }

    private (int ExitCode, string StdOut) RunProcessCapture(string exe, string[] args, string workingDir = null,
        bool checkExit = false)
    {
        using Process process = new();
        process.StartInfo.FileName = exe;
        process.StartInfo.UseShellExecute = false;
        process.StartInfo.CreateNoWindow = true;
        process.StartInfo.RedirectStandardOutput = true;
        process.StartInfo.RedirectStandardError = true;
        process.StartInfo.WorkingDirectory = workingDir ?? Path.GetTempPath();
        foreach (string arg in args)
            process.StartInfo.ArgumentList.Add(arg);

        process.Start();
        string stdout = process.StandardOutput.ReadToEnd();
        process.WaitForExit();
        string stderr = process.StandardError.ReadToEnd();
        if (checkExit && process.ExitCode != 0)
            throw new InvalidOperationException(
                $"{exe} failed (exit {process.ExitCode}): {(stderr + stdout).Trim()}");

        return (process.ExitCode, stdout);
    }
}
