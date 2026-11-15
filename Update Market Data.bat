@echo off
rem Downloads the latest WoW Forever AH prices for the Market Data tab. Type /reload in game afterwards.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\update-market-data.ps1"
pause
