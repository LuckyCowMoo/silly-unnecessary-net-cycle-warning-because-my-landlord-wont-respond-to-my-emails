@echo off
cd /d "%~dp0"
echo ================================================================
echo  Network outage detector (10 minutes, synced to clock)
echo ================================================================
echo.
echo  The test waits until the next :00, :05, :10, :15, :20, :25,
echo  :30, :35, :40, :45, :50, or :55, then runs for 10 minutes.
echo.
echo  Start this on both machines before that mark. Then play normally.
echo  When it finishes, share the summary from the logs\ folder.
echo.
set LABEL=%COMPUTERNAME%
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Test-PersistentFlow.ps1" -RateHz 20 -Label "%LABEL%"
echo.
echo Done. Summary is in the logs\ folder.
pause
