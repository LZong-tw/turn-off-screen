param([string]$TargetDirectory=(Join-Path $env:USERPROFILE 'Scripts'))
$ErrorActionPreference='Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$targetDir = [IO.Path]::GetFullPath($TargetDirectory)
$desktopDir = [Environment]::GetFolderPath("Desktop")

if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir | Out-Null }

Copy-Item "$scriptDir\TurnOffScreen.ps1" "$targetDir\TurnOffScreen.ps1" -Force
Copy-Item "$scriptDir\TurnOffScreen.vbs" "$targetDir\TurnOffScreen.vbs" -Force
foreach($file in @('MonitorPower.ps1','RestoreScreen.ps1','ScreenControl.cs')){Copy-Item -LiteralPath (Join-Path $scriptDir $file) -Destination (Join-Path $targetDir $file) -Force}
& "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe "/out:$targetDir\ScreenControl.exe" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll (Join-Path $targetDir 'ScreenControl.cs')
if($LASTEXITCODE -ne 0){throw 'ScreenControl build failed. Close the existing control window before installing.'}

# Fix VBS path to use installed location
$vbsContent = @"
Dim scriptDir : scriptDir = "$targetDir"
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptDir & "\TurnOffScreen.ps1""", 0, False
"@
Set-Content "$targetDir\TurnOffScreen.vbs" $vbsContent

# Create desktop shortcut
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut("$desktopDir\Turn Off Screen.lnk")
$sc.TargetPath = "wscript.exe"
$sc.Arguments = """$targetDir\TurnOffScreen.vbs"""
$sc.IconLocation = "$env:SystemRoot\System32\ddores.dll,1"
$sc.WindowStyle = 7
$sc.Description = "Toggle screen off (brightness 0 + black overlay)"
$sc.Save()
$controlName=-join ([char[]]@(0x87A2,0x5E55,0x63A7,0x5236))
$restoreName=-join ([char[]]@(0x6062,0x5FA9,0x87A2,0x5E55))
$control=$ws.CreateShortcut((Join-Path $desktopDir ($controlName+'.lnk')))
$control.TargetPath="$targetDir\ScreenControl.exe";$control.WorkingDirectory=$targetDir;$control.Save()
$restore=$ws.CreateShortcut((Join-Path $desktopDir ($restoreName+'.lnk')))
$restore.TargetPath="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$restore.Arguments="-NoProfile -STA -WindowStyle Hidden -File `"$targetDir\RestoreScreen.ps1`""
$restore.Hotkey='';$restore.WindowStyle=7;$restore.Description='Restore native display power and dismiss the night overlay';$restore.Save()

Write-Host "Installed to $targetDir"
Write-Host "Desktop shortcut created: Turn Off Screen"
Write-Host ""
Write-Host "Bind $targetDir\TurnOffScreen.vbs to a hotkey via:"
Write-Host "  - ASUS ExpertWidget (Fn+F10/F11/F12)"
Write-Host "  - Desktop shortcut properties (Ctrl+Alt+...)"
Write-Host "  - AutoHotkey"
