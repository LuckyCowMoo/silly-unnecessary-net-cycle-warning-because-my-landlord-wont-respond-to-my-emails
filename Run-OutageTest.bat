@echo off
cd /d "%~dp0"
echo ================================================================
echo  Network outage detector (5-minute persistent UDP test)
echo ================================================================
echo.
echo  Leave this window open. Play a game or browse normally.
echo  When it finishes, share the summary from the logs\ folder.
echo.
set LABEL=%COMPUTERNAME%
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Test-PersistentFlow.ps1" -DurationSec 300 -RateHz 20 -Label "%LABEL%"
echo.
echo Done. Summary is in the logs\ folder.
pause
