@echo off
rem dsh.cmd - command-line front end for the DeepSeek Harness launcher.
rem Put this directory on PATH and use `dsh status`, `dsh start`, `dsh doctor`,
rem and so on. It forwards every argument straight to dsh.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh.ps1" %*
