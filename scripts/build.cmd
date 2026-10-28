@echo off
rem =====================================================================
rem  build.cmd  -  ????
rem
rem  ??????????????????
rem
rem  ??????????? ASCII ??????????
rem        ????????? README.md ??
rem =====================================================================

setlocal
chcp 65001 >nul 2>&1

rem ---- ??????? ----
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo   Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

:MENU
cls
echo.
echo  ============================================================
echo              Differential Dual-Boot  (Base + Work)
echo  ============================================================
echo.
echo    [0] Environment check          00-check.ps1      (read only)
echo    [1] Prepare (backup BCD, etc)  01-prepare.ps1
echo    [2] Create Base.vhdx           02-create-base.ps1
echo    [3] Add Base boot entry        03-add-base-entry.ps1
echo    [4] Seal Base (read-only)      04-seal-base.ps1
echo    [5] Create Work (derive)       05-create-work.ps1
echo    [6] Reset Work                 05-create-work.ps1 -Reset
echo    [7] Rollback menu              99-rollback.ps1
echo.
echo    [R] Read README.md
echo    [Q] Quit
echo.
echo  ============================================================
echo.

set /p CHOICE=  Select: 

if /i "%CHOICE%"=="0" goto RUN0
if /i "%CHOICE%"=="1" goto RUN1
if /i "%CHOICE%"=="2" goto RUN2
if /i "%CHOICE%"=="3" goto RUN3
if /i "%CHOICE%"=="4" goto RUN4
if /i "%CHOICE%"=="5" goto RUN5
if /i "%CHOICE%"=="6" goto RESET
if /i "%CHOICE%"=="7" goto ROLLBACK
if /i "%CHOICE%"=="R" goto README
if /i "%CHOICE%"=="Q" exit /b 0
goto MENU

:RUN0
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File ".\00-check.ps1"
goto PAUSE

:RUN1
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File ".\01-prepare.ps1"
goto PAUSE

:RUN2
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File ".\02-create-base.ps1"
goto PAUSE

:RUN3
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File ".\03-add-base-entry.ps1"
goto PAUSE

:RUN4
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File ".\04-seal-base.ps1"
goto PAUSE

:RUN5
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File ".\05-create-work.ps1"
goto PAUSE

:RESET
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File ".\05-create-work.ps1" -Reset
goto PAUSE

:ROLLBACK
echo.
echo   Rollback options:
echo     [1] Remove Base boot entry
echo     [2] Remove Work boot entry
echo     [3] Restore environment settings
echo     [4] Unseal Base (make writable)
echo     [5] Restore BCD from backup  (LAST RESORT)
echo     [B] Back
echo.
set /p RB=  Select: 
if /i "%RB%"=="1" powershell -NoProfile -ExecutionPolicy Bypass -File ".\99-rollback.ps1" -BaseEntry
if /i "%RB%"=="2" powershell -NoProfile -ExecutionPolicy Bypass -File ".\99-rollback.ps1" -WorkEntry
if /i "%RB%"=="3" powershell -NoProfile -ExecutionPolicy Bypass -File ".\99-rollback.ps1" -Env
if /i "%RB%"=="4" powershell -NoProfile -ExecutionPolicy Bypass -File ".\99-rollback.ps1" -Unseal
if /i "%RB%"=="5" powershell -NoProfile -ExecutionPolicy Bypass -File ".\99-rollback.ps1" -Bcd
goto PAUSE

:README
cls
if exist ".\README.md" (
    powershell -NoProfile -Command "Get-Content '.\README.md' -Encoding UTF8 | Out-Host"
) else (
    echo   README.md not found.
)
goto PAUSE

:PAUSE
echo.
echo  ------------------------------------------------------------
pause
goto MENU
