@echo off
rem Refreshes the Market Data tab's prices every hour in the background (Windows Task Scheduler, your user only).
rem The game reads the new data the next time you log in or type /reload.
schtasks /Create /F /SC HOURLY /TN "AHPriceTracker Market Data" /TR "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%~dp0tools\update-market-data.ps1\""
if %errorlevel%==0 (
  echo.
  echo Hourly market data updates are ON. Run "Hourly Market Data - Off.bat" to stop them.
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\update-market-data.ps1"
)
pause
