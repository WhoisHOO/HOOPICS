@echo off
rem HOOPICS: double-click to open, or drop image files onto this file.
rem The window is PowerShell + WPF, both built into Windows 10/11, so nothing needs installing.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0app\HOOPICS.ps1" %*
