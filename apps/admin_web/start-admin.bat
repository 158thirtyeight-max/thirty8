@echo off
title Admin Panel (Next.js dev server)
cd /d "%~dp0"

if not exist node_modules (
    echo Installing dependencies...
    call npm install
    if errorlevel 1 (
        echo npm install failed.
        pause
        exit /b 1
    )
)

echo Starting admin panel...
rem Open the browser after giving the server a few seconds to boot
start "" /b cmd /c "timeout /t 6 /nobreak >nul & start http://localhost:3000"

call npm run dev
pause
