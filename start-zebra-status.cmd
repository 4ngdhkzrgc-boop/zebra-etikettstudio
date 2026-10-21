@echo off
setlocal
title Zebra Etikettstudio - PowerShell hjelper
set "PSFILE=%~dp0zebra-status-windows.ps1"
if not exist "%PSFILE%" (
  echo FANT IKKE: zebra-status-windows.ps1
  echo Legg .cmd-filen og .ps1-filen i SAMME mappe, for eksempel Nedlastinger.
  echo Last ned begge filene fra Zebra Etikettstudio.
  pause
  exit /b 1
)
echo Starter Zebra Etikettstudio status-hjelper.
echo Dette vinduet vil holde PowerShell apent selv om det oppstar feil.
echo Stopp hjelpen med Ctrl+C, og lukk deretter PowerShell-vinduet.
echo.
powershell.exe -NoLogo -NoProfile -NoExit -File "%PSFILE%"
if errorlevel 1 (
  echo.
  echo PowerShell kunne ikke kjore hjelpen. Se feilmeldingen over.
  echo Folg bedriftens sikkerhetspolicy; ikke endre kjorepolicy uten IT-godkjenning.
  pause
)
