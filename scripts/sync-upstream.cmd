@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0.."
if not exist "%~dp0sync-upstream.ps1" (
  echo 找不到 PowerShell 脚本：%~dp0sync-upstream.ps1
  set "RESULT=2"
  goto finish
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-upstream.ps1"
set "RESULT=%ERRORLEVEL%"
:finish
echo.
if not "%RESULT%"=="0" (
  echo 同步未完成，请查看上方提示后再重试。
)
echo 按任意键关闭此窗口……
pause >nul
exit /b %RESULT%
