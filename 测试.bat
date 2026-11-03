@echo off
setlocal
title Snore Detect - Guided Test
cd /d "%~dp0"

set "PORT=%~1"
if "%PORT%"=="" set "PORT=COM7"

rem ---------- locate python ----------
set "PY=C:\Users\Chen Yuhang\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
if exist "%PY%" goto havepy
set "PY=python"
where python >nul 2>nul
if errorlevel 1 goto nopy
:havepy

echo.
echo  ============================================================
echo    Snore Detect - Guided Test      port %PORT%
echo  ============================================================
echo.
echo   Before you start:
echo     1. FPGA bitstream is already downloaded
echo        (must download again after power off)
echo     2. Close serial monitors / anything else using %PORT%
echo     3. Have your snoring recording ready (phone speaker is fine)
echo     4. Volume max, mic 10-15 cm from the speaker
echo.
echo   Total about 106 seconds. Just follow the on-screen prompts,
echo   no keyboard input needed during the test.
echo.
pause

"%PY%" "%~dp0scripts\snore_test.py" %PORT%
set "RC=%ERRORLEVEL%"

echo.
echo  ------------------------------------------------------------
echo    Finished.  exit code = %RC%
echo    Detail data saved to  scripts\snore_test.csv
echo  ------------------------------------------------------------
if not "%RC%"=="0" echo  [!] Non-zero exit code, read the messages above.
echo.
pause
rem keep on one line: the whole line is expanded before endlocal runs
endlocal & exit /b %RC%

:nopy
echo.
echo  [ERROR] python not found.
echo  Install Python, or edit the PY variable at the top of this file
echo  to point to your python.exe
echo.
pause
endlocal
exit /b 1
