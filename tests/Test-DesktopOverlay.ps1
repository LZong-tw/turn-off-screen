$ErrorActionPreference='Stop'
$target=Join-Path (Split-Path $PSScriptRoot) 'TurnOffScreen.ps1'
function Status { (& powershell.exe -NoProfile -STA -File $target -Action Status)|ConvertFrom-Json }
if((Status).Active){throw 'An overlay is already active; leave the user session unchanged'}
$first=$null
try {
    $first=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -STA -File `"$target`" -Action On -NoBrightness"
    Start-Sleep -Seconds 3
    if(-not (Status).Active){throw 'Desktop overlay did not start without WMI brightness'}
    $again=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -STA -File `"$target`" -Action On -NoBrightness"
    if(-not $again.WaitForExit(8000)){throw 'Second On command did not exit'}
    if(-not (Status).Active -or $first.HasExited){throw 'On toggled an already active desktop overlay off'}
    & powershell.exe -NoProfile -STA -File $target -Action Off
    if(-not $first.WaitForExit(10000)){throw 'Explicit Off did not dismiss the desktop overlay'}
    & powershell.exe -NoProfile -STA -File $target -Action Off
    if((Status).Active){throw 'Off while already off started a black overlay'}
    Write-Output 'PASS: no-brightness desktop overlay starts, repeated On stays on, and repeated Off stays off.'
}finally {
    & powershell.exe -NoProfile -STA -File $target -Action Off
    if($first -and -not $first.HasExited -and -not $first.WaitForExit(10000)){$first.Kill()}
}
