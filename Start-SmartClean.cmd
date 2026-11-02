@echo off
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
  python -m venv .venv
  if errorlevel 1 goto failure
  ".venv\Scripts\python.exe" -m pip install -e .
  if errorlevel 1 goto failure
)
start "" /b ".venv\Scripts\pythonw.exe" -m smartclean.desktop --data-dir "%~dp0.local"
if errorlevel 1 goto failure
exit /b
:failure
echo SmartClean could not start. Review the error above.
pause
