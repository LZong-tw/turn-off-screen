$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$targetDir = "$env:USERPROFILE\Scripts"
$desktopDir = [Environment]::GetFolderPath("Desktop")

if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir | Out-Null }

Copy-Item "$scriptDir\TurnOffScreen.ps1" "$targetDir\TurnOffScreen.ps1" -Force
Copy-Item "$scriptDir\TurnOffScreen.vbs" "$targetDir\TurnOffScreen.vbs" -Force

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

Write-Host "Installed to $targetDir"
Write-Host "Desktop shortcut created: Turn Off Screen"
Write-Host ""
Write-Host "Bind $targetDir\TurnOffScreen.vbs to a hotkey via:"
Write-Host "  - ASUS ExpertWidget (Fn+F10/F11/F12)"
Write-Host "  - Desktop shortcut properties (Ctrl+Alt+...)"
Write-Host "  - AutoHotkey"
