@echo off
pwsh.exe -NoLogo -NoProfile -File "%~dp0Optimize-Video.ps1" %*
exit /b %ERRORLEVEL%
