@echo off
setlocal
title Snore Detect - Tune Threshold
cd /d "%~dp0"

rem ---------- locate python ----------
set "PY=C:\Users\Chen Yuhang\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
if exist "%PY%" goto havepy
set "PY=python"
where python >nul 2>nul
if errorlevel 1 goto nopy
:havepy
set "CSV=%~dp0snore_test.csv"

echo.
echo  ============================================================
echo    Tune threshold from measured data
echo    (no board needed, no re-synthesis needed)
echo  ============================================================
echo.
echo   Prerequisite: you have run  test.bat  at least once, so that
echo   snore_test.csv exists in this folder.
echo.
echo   How it works: the csv stores the peak value of every frame.
echo   This tool replays the exact judge logic of snore_judge.v on
echo   the PC and grid-searches TH/ENV_SHIFT/MIN_ON/GAP_MIN, then tells
echo   you which combination detects snoring without false alarms.
echo.
if exist "%CSV%" goto run
echo  [ERROR] csv not found:  %CSV%
echo          Run  test.bat  first.
echo.
pause
endlocal
exit /b 1

:run
pause
"%PY%" "%~dp0scripts\tune.py" "%CSV%"
set "RC=%ERRORLEVEL%"

echo.
echo  ------------------------------------------------------------
echo    Finished.  exit code = %RC%
echo    Send the recommended parameter set to the
echo    assistant, it will patch the RTL and rebuild.
echo  ------------------------------------------------------------
echo.
pause
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
