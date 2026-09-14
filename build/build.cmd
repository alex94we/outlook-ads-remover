@echo off
setlocal enabledelayedexpansion
rem Compila OutlookAdFix.dll (x64) da src\OutlookAdFix.cpp
rem Richiede Visual Studio 2022 Build Tools con il carico di lavoro C++.

set "ROOT=%~dp0.."
set "SDK=%ROOT%\build\sdk"

if not exist "%SDK%\include\WebView2.h" (
    echo SDK WebView2 non trovato: lo scarico.
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0get-sdk.ps1" || goto :errore
)

set "VCVARS="
if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" (
    for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VCVARS=%%i\VC\Auxiliary\Build\vcvars64.bat"
)
if not defined VCVARS (
    for /f "delims=" %%i in ('where /r "%ProgramFiles(x86)%\Microsoft Visual Studio" vcvars64.bat 2^>nul') do set "VCVARS=%%i"
)
if not defined VCVARS (
    echo ERRORE: non trovo vcvars64.bat.
    echo Installa Visual Studio 2022 Build Tools con il carico di lavoro
    echo "Sviluppo di applicazioni desktop con C++".
    goto :errore
)

call "%VCVARS%" >nul
cl /nologo /LD /O2 /MT /EHsc /DUNICODE /D_UNICODE /I"%SDK%\include" "%ROOT%\src\OutlookAdFix.cpp" /Fo"%ROOT%\build\\" /Fe:"%ROOT%\OutlookAdFix.dll" /link /DLL
if errorlevel 1 goto :errore

echo.
echo Compilazione completata: %ROOT%\OutlookAdFix.dll
exit /b 0

:errore
echo.
echo Compilazione NON riuscita.
exit /b 1
