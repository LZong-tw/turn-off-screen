# Regression test: the overlay must re-apply WDA_EXCLUDEFROMCAPTURE after it is lost.
#
# Background. The overlay hides itself from screen capture so that Chrome Remote
# Desktop viewers see the real desktop instead of the black screen. Originally the flag was
# applied once at Add_Shown and re-applied only on PowerModeChanged /
# DisplaySettingsChanged / SessionSwitch. A dwm.exe restart raises none of those three,
# and it does drop the effect -- so a viewer connected over Chrome Remote Desktop got a
# black screen with no way to recover short of toggling the overlay off and on.
#
# Why the flag is cleared instead of restarting dwm: restarting dwm blanks the
# interactive session and is not something a test should do to a developer's machine.
# Clearing to WDA_NONE works as a stand-in because display affinity is stored in win32k
# and GetWindowDisplayAffinity reads that real state back.
#
# Only the process that owns a window may change its display affinity; anyone else gets
# win32 error 5. So the clear happens inside the overlay, triggered by the file named in
# TURNOFFSCREEN_FAKE_AFFINITY_LOSS_FLAG. The check reads the affinity from out here.
#
# The re-apply is unconditional on a timer for a reason this test cannot cover: after a
# dwm restart win32k still reports WDA_EXCLUDEFROMCAPTURE even though it no longer has
# any effect, so a "check, then repair if changed" guard would be a permanent no-op. A
# manual clear IS visible to the getter, so a conditional implementation would still
# pass here. Keep the invariant in mind when changing TurnOffScreen.ps1.
#
# The test starts and stops its own overlay; the local screen goes dark for a few seconds.
# Exit codes: 0 pass, 1 fail, 2 skipped (overlay already running, or no WMI brightness).

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class OverlayProbe {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowDisplayAffinity(IntPtr h, out uint affinity);

    public const uint WDA_EXCLUDEFROMCAPTURE = 0x00000011;

    // FindWindow does not locate this window: WDA_EXCLUDEFROMCAPTURE combined with
    // WS_EX_TOOLWINDOW keeps it out of the lookup FindWindow uses. EnumWindows does.
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
$WAIT_SECONDS = 8      # must exceed the re-apply interval in TurnOffScreen.ps1
$target = Join-Path (Split-Path $PSScriptRoot) 'TurnOffScreen.ps1'
$lossFlag = Join-Path $env:TEMP "TurnOffScreen_fake_loss_$PID.flag"
$logFile = Join-Path $env:LOCALAPPDATA 'TurnOffScreen\TurnOffScreen.log'

function Get-Affinity($h) {
    $a = 0
    [void][OverlayProbe]::GetWindowDisplayAffinity($h, [ref]$a)
    $a
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
    Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$target`"")
}

if ([OverlayProbe]::FindByTitle($TITLE) -ne [IntPtr]::Zero) {
    Write-Host 'SKIP: overlay already running. Turn it off first.' -ForegroundColor Yellow
    exit 2
}
try {
    $original = (Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightness).CurrentBrightness
} catch {
    Write-Host 'SKIP: no WMI brightness on this machine.' -ForegroundColor Yellow
    exit 2
}

$proc = $null
$result = 1
$env:TURNOFFSCREEN_FAKE_AFFINITY_LOSS_FLAG = $lossFlag
try {
    $proc = Start-Overlay
    Remove-Item Env:\TURNOFFSCREEN_FAKE_AFFINITY_LOSS_FLAG

    $hwnd = [IntPtr]::Zero
    [void](Wait-Until { $script:hwnd = [OverlayProbe]::FindByTitle($TITLE); $script:hwnd -ne [IntPtr]::Zero } 8)
    if ($hwnd -eq [IntPtr]::Zero) { throw 'overlay window never appeared' }
    Write-Host "overlay hwnd = $hwnd"

    $affinity = Get-Affinity $hwnd
    Write-Host ("initial affinity = 0x{0:X}" -f $affinity)
    if ($affinity -ne [OverlayProbe]::WDA_EXCLUDEFROMCAPTURE) {
        throw 'overlay did not have WDA_EXCLUDEFROMCAPTURE to begin with'
    }

    Write-Host 'simulating flag loss inside the overlay'
    $marker = "[$($proc.Id)] simulated affinity loss, now 0x0"
    New-Item -ItemType File -Path $lossFlag -Force | Out-Null
    $cleared = Wait-Until {
        (Test-Path $logFile) -and (Get-Content $logFile -Tail 20 | Where-Object { $_.Contains($marker) })
    } 5
    if (-not $cleared) { throw 'the clear did not take effect, so this test proves nothing' }
    Write-Host 'cleared, now 0x0'

    Write-Host "waiting up to $WAIT_SECONDS s for the overlay to restore it..."
    $restored = Wait-Until { (Get-Affinity $hwnd) -eq [OverlayProbe]::WDA_EXCLUDEFROMCAPTURE } $WAIT_SECONDS
    if ($restored) {
        Write-Host 'PASS: flag restored automatically (0x11)' -ForegroundColor Green
        $result = 0
    } else {
        Write-Host ("FAIL: not restored within {0} s, affinity still 0x{1:X}." -f $WAIT_SECONDS, (Get-Affinity $hwnd)) -ForegroundColor Red
    }
} catch {
    Write-Host "FAIL: $_" -ForegroundColor Red
} finally {
    Remove-Item $lossFlag -ErrorAction SilentlyContinue
    if ($proc -and -not $proc.HasExited) {
        # A second launch toggles the overlay off and restores brightness.
        $off = Start-Overlay
        if (-not $proc.WaitForExit(8000)) { $proc.Kill() }
        [void]$off.WaitForExit(5000)
    }
    $now = (Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightness).CurrentBrightness
    if ($now -ne $original) {
        [void](Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods).WmiSetBrightness(1, $original)
    }
}
exit $result
