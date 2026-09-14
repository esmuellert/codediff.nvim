@echo off
REM Selection and workers are shared with POSIX in framework/supervisor.lua.
REM CODEDIFF_TEST_TARGET is overridden by an explicit positional target.
REM CODEDIFF_TEST_JOBS and CODEDIFF_TEST_TIMEOUT control workers and timeouts.
setlocal

if not "%~2"=="" goto usage_error
if "%~1"=="-h" goto usage
if "%~1"=="--help" goto usage
if not "%~1"=="" set "CODEDIFF_TEST_TARGET=%~1"

pushd "%~dp0.."
nvim --headless --noplugin -u tests/init.lua -c "lua require('tests.framework').run_all_and_exit()"
set EXIT_CODE=%ERRORLEVEL%
popd
exit /b %EXIT_CODE%

:usage_error
call :usage
exit /b 2

:usage
 echo Usage: %~nx0 [all^|unit^|integration^|e2e^|directory^|spec]
 echo Examples: %~nx0 e2e; %~nx0 tests/integration/core/git
exit /b 0
