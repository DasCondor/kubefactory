@echo off
rem KubeFactory launcher. Extra arguments are passed to the game, e.g.
rem   play.bat --demo                      built-in simulated cluster
rem   play.bat --sim=aws-eks-prod          simulated AWS / Azure / GKE / Rancher cluster
rem   play.bat --context=my-aks-cluster    a specific kubeconfig context
rem   play.bat --read-only                 look, don't touch
setlocal
set "GODOT=%~dp0engine\Godot_v4.3-stable_win64.exe"
if not exist "%GODOT%" (
  echo Godot engine not found. Run:  powershell -ExecutionPolicy Bypass -File "%~dp0tools\setup.ps1"
  pause
  exit /b 1
)
start "" "%GODOT%" --path "%~dp0." -- %*
