@echo off
setlocal
title Snore Detect - PC Control Panel
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
echo    Snore Detect - PC Control Panel
echo  ============================================================
echo.
echo   Before you start:
echo     1. FPGA bitstream downloaded (v4 or later, has cmd_parse)
echo     2. UART jumper on the PL side: "Connect 3&5 4&6"
echo     3. Close any serial monitor that holds the COM port
echo.
echo   This will start a small local web server (127.0.0.1:8765)
echo   and open your browser. In the page:
echo     - pick the COM port at the top, click Connect
echo     - four buttons: RT page / Report page / Toggle / Clear stats
echo     - every click is confirmed by the board itself
echo       (the G field of the telemetry frame echoes a command counter)
echo.
echo   Keep this window open while you use the page.
echo   Close it (or press Ctrl+C here) to stop the server.
echo.
pause

if "%~1"=="" goto nogui
"%PY%" "%~dp0scripts\snore_ctl.py" %~1
goto done

:nogui
"%PY%" "%~dp0scripts\snore_ctl.py"

:done
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo  [!] exit code = %RC%
if not "%RC%"=="0" pause
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
