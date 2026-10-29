# Native display-off regression: request delivery alone must not be called a successful panel-off.
# The local displays may go dark briefly. A finally block always sends the wake request.
$ErrorActionPreference='Stop'
$target=Join-Path (Split-Path $PSScriptRoot) 'MonitorPower.ps1'
try {
    $raw=& powershell.exe -NoProfile -STA -File $target -Action Off -DelaySeconds 2 -ObserveSeconds 4 -RestoreAfterObservation
    if($LASTEXITCODE -ne 0){throw 'Native off request failed'}
    $result=$raw|ConvertFrom-Json
    if(-not $result.RequestDelivered){throw 'Native request was not delivered'}
    if(@($result.Events|Where-Object State -eq 'Off').Count -eq 0){throw 'Windows never reported display Off; delivery is not proof of display state'}
    Write-Output 'PASS: Windows reported Off after the native request; wake request sent afterward.'
} finally {
    & powershell.exe -NoProfile -STA -File $target -Action On -DelaySeconds 0 -ObserveSeconds 1 | Out-Null
}
