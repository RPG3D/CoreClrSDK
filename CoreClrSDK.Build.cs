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

using System.IO;
using UnrealBuildTool;

public class CoreClrSDK : ModuleRules
{
    public CoreClrSDK(ReadOnlyTargetRules Target) : base(Target)
    {
        Type = ModuleType.External;

        // ModuleDirectory IS the SDK root (Source/ThirdParty/CoreClrSDK/).
        string sdkRoot = ModuleDirectory;

        // Expose coreclrhost.h (raw CoreCLR C API) so the host can include it.
        string includeDir = Path.Combine(sdkRoot, "include");
        if (Directory.Exists(includeDir))
        {
            PublicIncludePaths.Add(includeDir);
        }

        if (Target.Platform == UnrealTargetPlatform.Android
            || Target.Platform == UnrealTargetPlatform.IOS)
        {
            string bclSdkDir = Target.Platform == UnrealTargetPlatform.Android
                ? "Android"
                : "IOS";

            string contentPakDir = Target.Platform == UnrealTargetPlatform.Android
                ? "Android"
                : "IOS";
                
            string bclRuntimeDir = Path.Combine(sdkRoot, bclSdkDir, "runtime");

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

        if (Target.Platform == UnrealTargetPlatform.Android)
        {
            string nativeLibDir = Path.Combine(sdkRoot, "Android", "lib");

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

        if (Target.Platform == UnrealTargetPlatform.IOS)
        {
            string platformDir = "IOS";
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
            PublicAdditionalFrameworks.Add(new Framework(
                "CoreCLR",
                frameworkZip,
                Framework.FrameworkMode.LinkAndCopy,
                null));
        }
    }
}
