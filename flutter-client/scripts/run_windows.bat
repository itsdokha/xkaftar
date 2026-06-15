@echo off
setlocal

set "PROJECT_DIR=%~dp0.."
cd /d "%PROJECT_DIR%"

if "%APP_ENV%"=="" set "APP_ENV=production"
if "%API_BASE_URL%"=="" set "API_BASE_URL=https://kaftar.kuchizu.com"

echo Running flutter pub get...
call flutter pub get
if errorlevel 1 exit /b 1

echo Starting Windows app...
call flutter run -d windows --dart-define=APP_ENV=%APP_ENV% --dart-define=API_BASE_URL=%API_BASE_URL%
exit /b %errorlevel%
