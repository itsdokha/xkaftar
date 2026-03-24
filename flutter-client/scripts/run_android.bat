@echo off
setlocal

set "PROJECT_DIR=%~dp0.."
cd /d "%PROJECT_DIR%"

set "APP_ENV=production"
set "API_BASE_URL=https://kaftar.kuchizu.com"
set "DEVICE_ARG="

if not "%~1"=="" (
  set "DEVICE_ARG=-d %~1"
)

echo Running flutter pub get...
call flutter pub get
if errorlevel 1 exit /b 1

echo Starting Flutter on Android...
call flutter run %DEVICE_ARG% --dart-define=APP_ENV=%APP_ENV% --dart-define=API_BASE_URL=%API_BASE_URL%
if errorlevel 1 exit /b 1

exit /b 0
