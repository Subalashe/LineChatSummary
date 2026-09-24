@echo off
setlocal
if not exist "%~dp0LineChatSummary-Codex.exe" (
  echo LineChatSummary-Codex.exe was not found. Place it in this folder.
  pause
  exit /b 1
)
start "" "%~dp0LineChatSummary-Codex.exe"
endlocal
