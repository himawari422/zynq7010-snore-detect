@echo off
setlocal
title Snore Detect - Auto Segmented Test
cd /d "%~dp0"

rem ---------- locate python ----------
set "PY=C:/Users/Chen Yuhang\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
if exist "%PY%" goto havepy
set "PY=python"
where python >nul 2>nul
if errorlevel 1 goto nopy
:havepy

echo.
echo  ============================================================
echo    Snore Detect - Auto Segmented Test
echo  ============================================================
echo.
echo   This runs SIX segments by itself (about 102 seconds).
echo   The PC plays the sounds, you just wait.
echo.
echo     prep   4s  silence
echo     quiet 15s  silence
echo     speech15s  synthesized syllables
echo     clap  10s  1Hz transients
echo     snore 48s  snore_stim.wav
echo     quiet 10s  silence
echo.
echo   Before you start:
echo     1. board powered, bitstream downloaded
echo     2. serial cable on the UART port, PL side jumper
echo     3. laptop volume 100%%, close other audio apps
echo     4. put the mic 10-15cm in front of the speaker,
echo        or play the snore file from a phone (better bass)
echo.
echo   Watch the E_max column in the snore segment.
echo   Below 1000 means the stimulus is too weak, not the FPGA.
echo.
pause

set "PORT=%~1"
if "%PORT%"=="" set "PORT=COM7"
"%PY%" "%~dp0scripts\auto_test.py" %PORT%

set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo  [!] exit code = %RC%
pause
rem keep on one line: the whole line is expanded before endlocal runs
endlocal & exit /b %RC%

:nopy
echo.
echo  [ERROR] python not found.
echo  Install Python, or edit the PY variable at the top of this file.
echo.
pause
endlocal
exit /b 1
