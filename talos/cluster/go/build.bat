@echo off
REM Build script for Windows

echo Building talos-bootstrap...

if not exist build mkdir build

go build -o build\talos-bootstrap.exe cmd\main.go

if %ERRORLEVEL% == 0 (
    echo Build successful: build\talos-bootstrap.exe
    echo.
    echo Run with: build\talos-bootstrap.exe status
) else (
    echo Build failed!
    exit /b 1
)
