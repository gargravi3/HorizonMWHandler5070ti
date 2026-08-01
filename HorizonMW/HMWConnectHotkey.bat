@echo off
rem -STA is required: the watcher uses System.Windows.Forms.SendKeys.
start "" /min powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0HMWConnectHotkey.ps1"
