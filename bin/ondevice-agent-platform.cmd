@echo off
rem Repo-local launcher (Windows): run the platform from a checkout.
set "ROOT=%~dp0.."
set "PYTHONPATH=%ROOT%\python\src"
python -m ondevice_agent_platform %*
