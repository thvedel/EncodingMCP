@echo off
rem Build script for EncodingMCP and its test suite via msbuild on the .dproj files.
rem Configuration and platform respect what is set in the two .dproj files.
chcp 1252 >nul
setlocal enabledelayedexpansion

rem Use RSVARS environment variable if already set, otherwise auto-detect
if defined RSVARS (
  if exist "%RSVARS%" (
    echo Using RSVARS from environment variable: %RSVARS%
    goto :rsvars_found
  )
  echo WARNING: RSVARS is set but file does not exist: %RSVARS%
  set "RSVARS="
)

rem Try Delphi 13.1 (Studio 37.0) first, then Delphi 12.3 (Studio 23.0)
set "RSVARS_37=C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
set "RSVARS_23=C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat"
if exist "!RSVARS_37!" (
  set "RSVARS=!RSVARS_37!"
  echo Found Delphi 13.1
)
if "!RSVARS!"=="" if exist "!RSVARS_23!" (
  set "RSVARS=!RSVARS_23!"
  echo Found Delphi 12.3
)
if "!RSVARS!"=="" (
  echo ERROR: could not find rsvars.bat for Delphi 13.1 or 12.3
  echo Expected one of:
  echo   !RSVARS_37!
  echo   !RSVARS_23!
  exit /b 1
)
:rsvars_found
call "!RSVARS!" >nul

set "PLATFORM=Win64"
set "CONFIG=Release"

echo === Building main program (%PLATFORM% %CONFIG%) ===
msbuild EncodingMCP.dproj /t:Build /p:Config=%CONFIG% /p:Platform=%PLATFORM% /verbosity:minimal /nologo
if errorlevel 1 goto :err

echo === Building test suite (%PLATFORM% %CONFIG%) ===
msbuild tests\EncodingMCPTests.dproj /t:Build /p:Config=%CONFIG% /p:Platform=%PLATFORM% /verbosity:minimal /nologo
if errorlevel 1 goto :err

set "MAIN_EXE=build\%PLATFORM%\%CONFIG%\EncodingMCP.exe"
set "TEST_EXE=build\%PLATFORM%\%CONFIG%\EncodingMCPTests.exe"

if not exist "%MAIN_EXE%" (
  echo ERROR: expected %MAIN_EXE% after build, but file does not exist
  goto :err
)
if not exist "%TEST_EXE%" (
  echo ERROR: expected %TEST_EXE% after build, but file does not exist
  goto :err
)

echo === Running tests ===
"%TEST_EXE%" --exit:Continue
if errorlevel 1 goto :err

echo.
echo === Build OK ===
echo   Server: %MAIN_EXE%
echo   Tests:  %TEST_EXE%
exit /b 0

:err
echo BUILD FAILED
exit /b 1
