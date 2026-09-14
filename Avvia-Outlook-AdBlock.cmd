@echo off
setlocal
title Outlook-AdBlock

rem Rilancia se stessa con i privilegi di amministratore (servono per System32 e per il registro).
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Richiesta dei privilegi di amministratore...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Outlook-AdBlock.ps1" %*

echo.
pause
endlocal
