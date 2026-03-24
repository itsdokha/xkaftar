@echo off
setlocal

set "PROJECT_DIR=%~dp0.."
cd /d "%PROJECT_DIR%"

set "APP_ENV=production"
set "API_BASE_URL=https://kaftar.kuchizu.com"

echo Bumping Flutter build number...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$path = Join-Path '%PROJECT_DIR%' 'pubspec.yaml';" ^
  "$content = Get-Content $path -Raw;" ^
  "if ($content -match 'version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)') {" ^
  "  $version = $matches[1];" ^
  "  $build = [int]$matches[2] + 1;" ^
  "  $newLine = \"version: $version+$build\";" ^
  "  $content = [regex]::Replace($content, 'version:\s*[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+', $newLine, 1);" ^
  "  Set-Content $path $content -Encoding UTF8;" ^
  "  Write-Host \"Updated to $newLine\";" ^
  "} else {" ^
  "  Write-Error 'version line not found in pubspec.yaml';" ^
  "  exit 1;" ^
  "}"
if errorlevel 1 exit /b 1

echo Running flutter pub get...
call flutter pub get
if errorlevel 1 exit /b 1

echo Building Windows release...
call flutter build windows --release --dart-define=APP_ENV=%APP_ENV% --dart-define=API_BASE_URL=%API_BASE_URL%
if errorlevel 1 exit /b 1

echo.
echo Windows build complete.
echo Output: build\windows\x64\runner\Release\
exit /b 0
