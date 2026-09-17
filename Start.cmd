@echo off
rem ---------------------------------------------------------------------------
rem Start.cmd - open the dsh-deck panel. This is the file to double-click.
rem
rem Why this exists, and why it is not a .lnk:
rem
rem A Windows shortcut stores ABSOLUTE paths - the PowerShell executable, the
rem path to dsh.ps1, the working directory and the icon are all baked in as
rem full paths, and the file itself is binary. A .lnk committed to this repo
rem would therefore point at the machine that generated it and be useless (or
rem silently wrong) for everyone else. The repo also ignores *.lnk on purpose,
rem because a shortcut is a per-user artefact.
rem
rem A .cmd has none of those problems. %~dp0 is the directory this file was
rem launched from, so it works from any path, from a fresh clone, before
rem anything is installed, with no configuration and no terminal knowledge.
rem Double-clicking dsh.ps1 does NOT do this: Windows opens .ps1 files for
rem editing by default, which is how "just double-click it" quietly fails.
rem
rem For a desktop or Start Menu icon with the panel's own artwork, run:
rem   powershell -File tools\install-shortcut.ps1
rem ---------------------------------------------------------------------------
setlocal

set "LAUNCHER=%~dp0dsh.ps1"
if not exist "%LAUNCHER%" (
  echo.
  echo   Cannot find dsh.ps1 next to this file.
  echo   Expected: "%LAUNCHER%"
  echo.
  pause
  exit /b 1
)

rem Keep startup diagnostics visible. Missing Node is a recoverable first-run
rem condition, not a reason for a double-click to silently close its window.
powershell -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER%" -Command app
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo   The panel did not start ^(exit code %RC%^).
  echo.
  echo   First-time setup ^(explicitly installs Node/dsh when needed^):
  echo     powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh.ps1" -Command install -Target local
  echo.
  echo   Check the environment:
  echo     powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh.ps1" -Command doctor
  echo.
  pause
  exit /b %RC%
)

rem The backend is detached and the browser window is already opening, so this
rem console has done its job.
exit /b 0
