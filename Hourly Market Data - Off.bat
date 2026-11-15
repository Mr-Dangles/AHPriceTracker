@echo off
rem Stops the hourly market data updates.
schtasks /Delete /F /TN "AHPriceTracker Market Data"
pause
