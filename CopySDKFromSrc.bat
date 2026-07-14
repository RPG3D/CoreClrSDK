@echo off
rem CopySDKFromSrc.bat
rem Copy CoreCLR SDK artifacts from dotnet/runtime build output into this SDK
rem repository's platform subdirectory (Win64).
rem
rem This script does NOT build dotnet/runtime — it only copies pre-built artifacts.
rem Use BuildCoreClrSDK.bat first to build, then this script to copy.
rem
rem Usage:
rem   CopySDKFromSrc.bat <dotnet-src-dir> [build-type]
rem
rem Arguments:
rem   dotnet-src-dir   Path to the dotnet/runtime repository root (must be already built).
rem   build-type       Debug (default) | Release
rem
rem Example:
rem   CopySDKFromSrc.bat C:\Code\DotNet
rem   CopySDKFromSrc.bat C:\Code\DotNet Release

setlocal enabledelayedexpansion

rem -- Arguments -------------------------------------------------------------------
if "%~1"=="" (
    echo Error: dotnet source directory is required. >&2
    echo Usage: %~nx0 ^<dotnet-src-dir^> [build-type] >&2
    exit /b 1
)

set "DOTNET_SRC=%~f1"
set "SDK_DIR=%~dp0"
if "%SDK_DIR:~-1%"=="\" set "SDK_DIR=%SDK_DIR:~0,-1%"

rem Build type: Debug (default) or Release
set "BUILD_TYPE_RAW=%~2"
if "%BUILD_TYPE_RAW%"=="" set "BUILD_TYPE_RAW=Debug"
echo %BUILD_TYPE_RAW% | findstr /i "Debug Release" >nul
if errorlevel 1 (
    echo Error: unknown build-type '%BUILD_TYPE_RAW%'. Use Debug or Release. >&2
    exit /b 1
)
set "BUILD_TYPE=Debug"
if /i "%BUILD_TYPE_RAW%"=="Release" set "BUILD_TYPE=Release"

echo === CopySDKFromSrc ===
echo   Source    : %DOTNET_SRC%
echo   Platform  : Win64
echo   Build type: %BUILD_TYPE%
echo   SDK dir   : %SDK_DIR%
echo.

rem -- Copy artifacts --------------------------------------------------------------
set "SRC_ARTIFACTS=%DOTNET_SRC%\artifacts"
set "CORECLR_TRIPLE=win.x64.%BUILD_TYPE%"
set "RUNTIME_RID=win-x64"
set "DEST=%SDK_DIR%\win64"

if exist "%DEST%" rmdir /s /q "%DEST%"
mkdir "%DEST%\lib" "%DEST%\runtime"

set "ROBOCOPY_ERROR=0"

rem 1. CoreCLR runtime engines (from coreclr artifacts, no "lib" prefix on Windows)
echo ^>^>^> Copying native libraries...

set "CORECLR_DIR=%SRC_ARTIFACTS%\bin\coreclr\%CORECLR_TRIPLE%"
if exist "%CORECLR_DIR%" (
    for %%f in (coreclr.dll clrjit.dll clrinterpreter.dll) do (
        if exist "%CORECLR_DIR%\%%f" (
            copy /y "%CORECLR_DIR%\%%f" "%DEST%\lib\" >nul
            echo   %%f
        )
    )
)

rem 2. System native shims (from runtime pack native, no "lib" prefix on Windows)
set "RUNTIME_PACK_NATIVE=%SRC_ARTIFACTS%\bin\microsoft.netcore.app.runtime.%RUNTIME_RID%\%BUILD_TYPE%\runtimes\%RUNTIME_RID%\native"
if exist "%RUNTIME_PACK_NATIVE%" (
    for %%f in (System.Native.dll System.IO.Compression.Native.dll System.Globalization.Native.dll System.Net.Security.Native.dll) do (
        if exist "%RUNTIME_PACK_NATIVE%\%%f" (
            copy /y "%RUNTIME_PACK_NATIVE%\%%f" "%DEST%\lib\" >nul
            echo   %%f
        )
    )
)

rem 3. BCL managed DLLs + PDBs (robocopy /E entire directory, like MonoSDK)
echo ^>^>^> Copying BCL managed DLLs + PDBs...

set "RUNTIME_PACK_MANAGED=%SRC_ARTIFACTS%\bin\microsoft.netcore.app.runtime.%RUNTIME_RID%\%BUILD_TYPE%\runtimes\%RUNTIME_RID%\lib\net10.0"
if exist "%RUNTIME_PACK_MANAGED%" (
    robocopy "%RUNTIME_PACK_MANAGED%" "%DEST%\runtime" /E /NFL /NDL
    if errorlevel 8 set "ROBOCOPY_ERROR=1"
) else (
    echo ERROR: Runtime pack managed DLLs not found at %RUNTIME_PACK_MANAGED% >&2
    exit /b 1
)

rem 4. Overwrite System.Private.CoreLib.dll with pure-IL version
set "CORECLR_IL=%CORECLR_DIR%\IL\System.Private.CoreLib.dll"
if exist "%CORECLR_IL%" (
    copy /y "%CORECLR_IL%" "%DEST%\runtime\System.Private.CoreLib.dll" >nul
    echo   System.Private.CoreLib.dll ^(pure-IL from CoreCLR IL/^)
    if exist "%CORECLR_DIR%\IL\System.Private.CoreLib.pdb" (
        copy /y "%CORECLR_DIR%\IL\System.Private.CoreLib.pdb" "%DEST%\runtime\System.Private.CoreLib.pdb" >nul
        echo   System.Private.CoreLib.pdb
    )
)

if "%ROBOCOPY_ERROR%"=="1" (
    echo ERROR: One or more source directories not found. >&2
    exit /b 1
)

rem -- Write VERSION.txt ----------------------------------------------------------
for /f "delims=" %%b in ('git -C "%DOTNET_SRC%" rev-parse --abbrev-ref HEAD 2^>nul') do set "DOTNET_BRANCH=%%b"
for /f "delims=" %%c in ('git -C "%DOTNET_SRC%" rev-parse --short HEAD 2^>nul')      do set "DOTNET_COMMIT=%%c"
for /f "delims=" %%r in ('git -C "%DOTNET_SRC%" remote get-url origin 2^>nul')       do set "DOTNET_REMOTE=%%r"

(
    echo dotnet/runtime source
    echo   repo:   %DOTNET_REMOTE%
    echo   branch: %DOTNET_BRANCH%
    echo   commit: %DOTNET_COMMIT%
    echo.
    echo Platform: Windows ^(x64^)
    echo Build type: %BUILD_TYPE%
    echo Build subsets: clr.runtime+clr.alljits+clr.corelib+clr.nativecorelib+clr.tools+clr.packages+libs
) > "%DEST%\VERSION.txt"

echo ^>^>^> Done. SDK updated at: %DEST%
endlocal
