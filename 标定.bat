@echo off
setlocal
title Snore Detect - Calibration
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
echo    Threshold Calibration      port %PORT%
echo  ============================================================
echo.
echo   Close serial monitors before running (one COM port, one app).
echo   Three 20-second captures: quiet / speech / snore.
echo.
pause

"%PY%" "%~dp0scripts\calib.py" %PORT% %2 %3 %4
set "RC=%ERRORLEVEL%"

echo.
echo  ------------------------------------------------------------
echo    Finished.  exit code = %RC%
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
