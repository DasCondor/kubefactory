@echo off
rem KubeFactory Docker edition from source: your local Docker engine as the factory.
rem Every container is a machine, Compose projects are namespaces. No kubectl involved.
call "%~dp0play.bat" --edition=docker %*
