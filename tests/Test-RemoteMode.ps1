# Regression test: while the session is away from the physical console (RDP), the overlay
# must get out of the way but the panel must stay dark.
#
# Background. RDP remotes the composed session, so the capture-excluded overlay would black
# out an RDP viewer. The first fix dismissed the overlay on RDP connect, which also restored
# brightness: the physical panel then sat lit on the lock screen for the whole RDP session
# (console-lock display-off never fired on the ExpertBook). Launching the script from
# inside RDP did nothing at all.
#
# A real RDP connect can't be scripted on a client SKU (loopback RDP is refused while the
# console is in use), so TURNOFFSCREEN_FAKE_REMOTE_FLAG makes the script treat the session
# as remote while the named file exists. Only the detection is faked; brightness and the
# overlay window are real.
#
# Heads-up: this blacks out and dims the local screen for a few seconds per case.
#
# Exit codes: 0 pass, 1 fail, 2 skipped (overlay already running, or no WMI brightness).

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class RemoteProbe {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);

    public static IntPtr FindByTitle(string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            var sb = new StringBuilder(256);
            GetWindowTextW(h, sb, 256);
            if (sb.ToString() == title) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
"@

$TITLE = 'TurnOffScreen_Overlay_7F3A'
$script = Join-Path (Split-Path $PSScriptRoot) 'TurnOffScreen.ps1'
$flag = Join-Path $env:TEMP "TurnOffScreen_fake_remote_$PID.flag"

function Get-Brightness { [int](Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightness).CurrentBrightness }
function Set-Brightness([int]$v) { [void](Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods).WmiSetBrightness(1, $v) }
function Test-OverlayVisible {
    $h = [RemoteProbe]::FindByTitle($TITLE)
    ($h -ne [IntPtr]::Zero) -and [RemoteProbe]::IsWindowVisible($h)
}
function Wait-Until([scriptblock]$cond, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $cond) { return $true }
        Start-Sleep -Milliseconds 250
    }
    & $cond
}
function Start-Overlay {
    $env:TURNOFFSCREEN_FAKE_REMOTE_FLAG = $flag
    try {
        Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"")
    } finally { Remove-Item Env:\TURNOFFSCREEN_FAKE_REMOTE_FLAG }
}

if ([RemoteProbe]::FindByTitle($TITLE) -ne [IntPtr]::Zero) {
    Write-Host 'SKIP: overlay already running. Turn it off first.' -ForegroundColor Yellow
    exit 2
}
try { $original = Get-Brightness } catch {
    Write-Host 'SKIP: no WMI brightness on this machine.' -ForegroundColor Yellow
    exit 2
}
if ($original -le 0) { Set-Brightness 50; $original = 50 }

$failures = @()
function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "  ok   $what" -ForegroundColor Green }
    else { Write-Host "  FAIL $what" -ForegroundColor Red; $script:failures += $what }
}

$proc = $null
try {
    Write-Host 'case 1: launched while remote'
    New-Item -ItemType File -Path $flag -Force | Out-Null
    $proc = Start-Overlay
    Start-Sleep -Seconds 4
    Check (-not $proc.HasExited) 'stays resident'
    Check (-not (Test-OverlayVisible)) 'overlay not visible'
    Check ((Get-Brightness) -eq 0) 'brightness is 0'
    Remove-Item $flag
    Check (Wait-Until { $proc.HasExited } 8) 'exits once back on console'
    Check ((Get-Brightness) -eq $original) "brightness restored to $original"

    # A second launch would toggle a leftover instance off instead of starting fresh.
    if (-not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit(); Set-Brightness $original }

    Write-Host 'case 2: goes remote while the overlay is up'
    $proc = Start-Overlay
    Check (Wait-Until { Test-OverlayVisible } 8) 'overlay shown on console'
    New-Item -ItemType File -Path $flag -Force | Out-Null
    Check (Wait-Until { -not (Test-OverlayVisible) } 8) 'overlay hidden after going remote'
    Check (-not $proc.HasExited) 'stays resident'
    Check ((Get-Brightness) -eq 0) 'brightness still 0'
    Remove-Item $flag
    Check (Wait-Until { $proc.HasExited } 8) 'exits once back on console'
    Check ((Get-Brightness) -eq $original) "brightness restored to $original"
} finally {
    Remove-Item $flag -ErrorAction SilentlyContinue
    if ($proc -and -not $proc.HasExited) { $proc.Kill() }
    if ((Get-Brightness) -ne $original) { Set-Brightness $original }
}

if ($failures.Count) { Write-Host "FAIL: $($failures.Count) check(s)" -ForegroundColor Red; exit 1 }
Write-Host 'PASS' -ForegroundColor Green
exit 0
