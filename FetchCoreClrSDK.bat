@echo off
REM FetchCoreClrSDK.bat - fast path for Android: download the android-arm64 CoreCLR
REM runtime + BCL from NuGet and populate Android\arm64\{lib,runtime}.
REM
REM This skips the dotnet/runtime build entirely. It is only valid for Android (JIT);
REM iOS needs the pure-IL CoreLib produced by clr.corelib and therefore a real build.
REM
REM The CoreClrSDK binaries (.so / .dll) are git-ignored (large, version-bound build
REM artifacts). Run this script once after cloning (or when upgrading .NET).
REM
REM Usage:
REM   FetchCoreClrSDK.bat                              (pinned version, DotNetRuntime.version)
REM   FetchCoreClrSDK.bat 11.0.0-rc.1.26425.128        (explicit version)
REM
REM Requirements: PowerShell (Invoke-WebRequest / Expand-Archive) - bundled on Win10+.

setlocal enabledelayedexpansion

set "ARG_VERSION=%~1"

REM SDK root = directory of this script.
set "SDK_ROOT=%~dp0"
if "%SDK_ROOT:~-1%"=="\" set "SDK_ROOT=%SDK_ROOT:~0,-1%"

REM Pinned runtime version/TFM/subset — single source of truth: DotNetRuntime.version.
for /f "usebackq tokens=1,* delims==" %%a in ("%SDK_ROOT%\DotNetRuntime.version") do set "%%a=%%b"
if not "%ARG_VERSION%"=="" set "RUNTIME_VERSION=%ARG_VERSION%"
if "%RUNTIME_VERSION%"=="" (
  echo ERROR: RUNTIME_VERSION is empty in DotNetRuntime.version
  exit /b 1
)

set "RID=android-arm64"
set "NUGET_URL=https://globalcdn.nuget.org/packages/microsoft.netcore.app.runtime.%RID%.%RUNTIME_VERSION%.nupkg"
set "DEST=%SDK_ROOT%\Android\arm64"
set "LIB_DIR=%DEST%\lib"
set "RUNTIME_DIR=%DEST%\runtime"
set "WORK_DIR=%SDK_ROOT%\..\.FetchCoreClrSDK_tmp"

echo === FetchCoreClrSDK: .NET %RUNTIME_VERSION% (%RID%) ===
echo SDK dir: %DEST%

REM Clean any prior temp dir.
if exist "%WORK_DIR%" rmdir /S /Q "%WORK_DIR%"
mkdir "%WORK_DIR%" 2>nul

REM Download + extract the nupkg (it is a zip) via PowerShell.
echo Downloading %NUGET_URL% ...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "Invoke-WebRequest -Uri '%NUGET_URL%' -OutFile '%WORK_DIR%\runtime.zip';" ^
  "if ((Get-Item '%WORK_DIR%\runtime.zip').Length -eq 0) { Write-Error 'download empty'; exit 1 };" ^
  "Expand-Archive -Path '%WORK_DIR%\runtime.zip' -DestinationPath '%WORK_DIR%\extracted' -Force;"
if errorlevel 1 (
  echo ERROR: download/extract failed ^(check version %RUNTIME_VERSION% exists on NuGet^)
  rmdir /S /Q "%WORK_DIR%" 2>nul
  exit /b 1
)

REM Native .so -> Android\arm64\lib\ (only .so; skip .a/.dex/.jar).
if not exist "%LIB_DIR%" mkdir "%LIB_DIR%"
del /Q "%LIB_DIR%\*.so" 2>nul
copy /Y "%WORK_DIR%\extracted\runtimes\%RID%\native\*.so" "%LIB_DIR%\" >nul
echo Installed native .so to %LIB_DIR%

REM BCL managed .dll -> Android\arm64\runtime\.
if not exist "%RUNTIME_DIR%" mkdir "%RUNTIME_DIR%"
del /Q "%RUNTIME_DIR%\*.dll" 2>nul
copy /Y "%WORK_DIR%\extracted\runtimes\%RID%\lib\%DOTNET_TFM%\*.dll" "%RUNTIME_DIR%\" >nul

REM Count installed DLLs.
set "DLL_COUNT=0"
for %%f in ("%RUNTIME_DIR%\*.dll") do set /a "DLL_COUNT+=1"
echo Installed !DLL_COUNT! BCL .dll to %RUNTIME_DIR%

if not exist "%LIB_DIR%\libcoreclr.so" (
  echo ERROR: libcoreclr.so missing from the runtime pack.
  rmdir /S /Q "%WORK_DIR%" 2>nul
  exit /b 1
)

(
  echo NuGet runtime pack ^(no source build^)
  echo   package: microsoft.netcore.app.runtime.%RID%
  echo   version: %RUNTIME_VERSION%
  echo.
  echo Platform: Android ^(arm64^)
  echo Build type: Release ^(NuGet^)
  echo Build subsets: %BUILD_SUBSET% ^(runtime pack equivalent^)
) > "%DEST%\VERSION.txt"

REM Cleanup temp.
rmdir /S /Q "%WORK_DIR%" 2>nul

echo === Done. CoreClrSDK populated for %RID% ^(.NET %RUNTIME_VERSION%^). ===
endlocal
