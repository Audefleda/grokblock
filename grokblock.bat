@echo off
:: grokblock.bat — Starter fuer grokblock.ps1
:: Prueft Admin-Rechte und startet das PowerShell-Skript mit Bypass-Policy.

:: Admin-Rechte pruefen
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Fehlende Administrator-Rechte — starte UAC-Abfrage...
    powershell -NoProfile -WindowStyle Hidden -Command ^
        "Start-Process cmd -ArgumentList '/c cd /d ""%~dp0"" && ""%~f0"" %*' -Verb RunAs"
    exit /b
)

:: PowerShell-Skript im selben Verzeichnis ausfuehren
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0grokblock.ps1" %*
exit /b %errorlevel%
