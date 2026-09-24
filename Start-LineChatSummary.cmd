@echo off
setlocal
if not exist "%~dp0LineChatSummary.exe" (
  echo LineChatSummary.exe was not found. Place it in this folder.
  pause
  exit /b 1
)
start "" "%~dp0LineChatSummary.exe"
endlocal
