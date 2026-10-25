@echo off
cd /d "%~dp0"
start "" pythonw "%~dp0push_gui.py"
if errorlevel 1 (
    python "%~dp0push_gui.py"
    pause
)
