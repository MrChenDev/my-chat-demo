@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0.."
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-upstream.ps1"
set "RESULT=%ERRORLEVEL%"
echo.
if not "%RESULT%"=="0" (
  echo 同步未完成，请查看上方提示后再重试。
)
echo 按任意键关闭此窗口……
pause >nul
exit /b %RESULT%
