$ErrorActionPreference='Stop'
$off=Join-Path $PSScriptRoot 'TurnOffScreen.ps1'
$native=Join-Path $PSScriptRoot 'MonitorPower.ps1'
& powershell.exe -NoProfile -STA -File $off -Action Off
if($LASTEXITCODE -ne 0){throw 'Could not restore the overlay'}
& powershell.exe -NoProfile -STA -File $native -Action On -DelaySeconds 0 -ObserveSeconds 1 | Out-Null
if($LASTEXITCODE -ne 0){throw 'Could not send the native wake request'}
