@echo off
rem BuildCoreClrSDK.bat
rem Build CoreCLR runtime + BCL from dotnet/runtime source.
rem
rem This script ONLY builds. Use CopySDKFromSrc.sh afterwards (via Git Bash)
rem to populate the SDK platform directory with the build artifacts.
rem
rem Usage:
rem   BuildCoreClrSDK.bat <dotnet-src-dir>
rem
rem Arguments:
rem   dotnet-src-dir   Path to the dotnet/runtime repository root.
rem                    Platform is always Win64 on Windows.
rem
rem Example:
rem   BuildCoreClrSDK.bat C:\Code\DotNet

setlocal enabledelayedexpansion

rem -- Arguments -------------------------------------------------------------------
if "%~1"=="" (
    echo Error: dotnet source directory is required. >&2
    echo Usage: %~nx0 ^<dotnet-src-dir^> >&2
    exit /b 1
)

set "DOTNET_SRC=%~f1"

echo === BuildCoreClrSDK ===
echo   Source  : %DOTNET_SRC%
echo   Platform: Win64
echo.

rem -- Build -----------------------------------------------------------------------
cd /d "%DOTNET_SRC%"

echo ^>^>^> Building CoreCLR for Windows (x64)...
call "%DOTNET_SRC%\build.cmd" clr.runtime+clr.alljits+clr.corelib+clr.nativecorelib+clr.tools+clr.packages+libs -configuration Debug
if errorlevel 1 (
    echo Error: build failed. >&2
    exit /b 1
)

echo.
echo === Build done. Run CopySDKFromSrc.sh to populate the SDK directory. ===
endlocal
