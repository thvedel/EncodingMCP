@echo off
rem Build script til EncodingMCP og dens testsuite via msbuild paa .dproj-filerne.
rem Konfiguration og platform respekterer det der staar i de to .dproj-filer.
chcp 1252 >nul
setlocal

set "RSVARS=C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
if not exist "%RSVARS%" (
  echo FEJL: kunne ikke finde rsvars.bat - juster RSVARS i build.bat
  exit /b 1
)
call "%RSVARS%" >nul

set "PLATFORM=Win64"
set "CONFIG=Release"

echo === Bygger hovedprogram (%PLATFORM% %CONFIG%) ===
msbuild EncodingMCP.dproj /t:Build /p:Config=%CONFIG% /p:Platform=%PLATFORM% /verbosity:minimal /nologo
if errorlevel 1 goto :err

echo === Bygger testsuite (%PLATFORM% %CONFIG%) ===
msbuild tests\EncodingMCPTests.dproj /t:Build /p:Config=%CONFIG% /p:Platform=%PLATFORM% /verbosity:minimal /nologo
if errorlevel 1 goto :err

set "MAIN_EXE=build\%PLATFORM%\%CONFIG%\EncodingMCP.exe"
set "TEST_EXE=build\%PLATFORM%\%CONFIG%\EncodingMCPTests.exe"

if not exist "%MAIN_EXE%" (
  echo FEJL: forventede %MAIN_EXE% efter build, men filen findes ikke
  goto :err
)
if not exist "%TEST_EXE%" (
  echo FEJL: forventede %TEST_EXE% efter build, men filen findes ikke
  goto :err
)

echo === Korer tests ===
"%TEST_EXE%" --exit:Continue
if errorlevel 1 goto :err

echo.
echo === Build OK ===
echo   Server: %MAIN_EXE%
echo   Tester: %TEST_EXE%
exit /b 0

:err
echo BUILD FEJLEDE
exit /b 1
