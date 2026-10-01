@echo off
setlocal
set "PVM_DIR=%~dp0"
if "%PVM_DIR:~-1%"=="\" set "PVM_DIR=%PVM_DIR:~0,-1%"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$pvmDir = '%PVM_DIR%';" ^
  "$cur = [Environment]::GetEnvironmentVariable('Path','User');" ^
  "if (-not $cur) { $cur = '' };" ^
  "$parts = $cur -split ';' | Where-Object { $_ -ne '' };" ^
  "$found = $false;" ^
  "foreach ($p in $parts) { if ($p.TrimEnd('\') -ieq $pvmDir.TrimEnd('\')) { $found = $true; break } }" ^
  "if ($found) {" ^
  "  Write-Host 'PVM is already in user PATH:' $pvmDir -ForegroundColor Yellow;" ^
  "} else {" ^
  "  $new = if ($cur -eq '') { $pvmDir } else { $cur.TrimEnd(';') + ';' + $pvmDir };" ^
  "  [Environment]::SetEnvironmentVariable('Path', $new, 'User');" ^
  "  Write-Host 'Added to user PATH:' $pvmDir -ForegroundColor Green;" ^
  "  Write-Host 'Please restart your terminal.' -ForegroundColor Green;" ^
  "}"

echo.
echo Current user PATH entries:
powershell -NoProfile -Command "([Environment]::GetEnvironmentVariable('Path','User') -split ';') | Where-Object { $_ } | ForEach-Object { Write-Host '  ' $_ }"

echo.
pause