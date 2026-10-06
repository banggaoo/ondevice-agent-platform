@echo off
rem Repo-local launcher (Windows): run the platform from a checkout.
set "ROOT=%~dp0.."
set "PYTHONPATH=%ROOT%\python\src"
rem Probe each py-launcher version tag for a real >=3.11 interpreter;
rem the tag alone does not prove the installed version qualifies.
py -3.13 -c "import sys;sys.exit(0 if sys.version_info[:2]>=(3,11) else 1)" >nul 2>nul
if not errorlevel 1 (set "PY=py -3.13" & goto :run)
py -3.12 -c "import sys;sys.exit(0 if sys.version_info[:2]>=(3,11) else 1)" >nul 2>nul
if not errorlevel 1 (set "PY=py -3.12" & goto :run)
py -3.11 -c "import sys;sys.exit(0 if sys.version_info[:2]>=(3,11) else 1)" >nul 2>nul
if not errorlevel 1 (set "PY=py -3.11" & goto :run)
py -3 -c "import sys;sys.exit(0 if sys.version_info[:2]>=(3,11) else 1)" >nul 2>nul
if not errorlevel 1 (set "PY=py -3" & goto :run)
python -c "import sys;sys.exit(0 if sys.version_info[:2]>=(3,11) else 1)" >nul 2>nul
if not errorlevel 1 (set "PY=python" & goto :run)
echo error: ondevice-agent-platform needs Python 3.11 or newer on PATH 1>&2
exit /b 1
:run
%PY% -m ondevice_agent_platform %*
exit /b %errorlevel%
