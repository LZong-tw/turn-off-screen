# Regression test: after a real dwm.exe restart the overlay must stay hidden from screen capture.
#
# Background. dwm crashes under memory exhaustion (seen as 0xc00001ad on the ExpertBook) and
# Windows restarts it. The overlay then started showing up in captures, so a Chrome Remote
# Desktop viewer saw a black screen. The earlier fix re-applied WDA_EXCLUDEFROMCAPTURE every
# 2 seconds; this test showed that does nothing, because win32k still believes the flag is set
# and treats setting the same value as a no-op. Clearing it and setting it again works.
#
# Test-OverlayReapply.ps1 cannot catch this: it clears the flag by hand, which IS visible to
# win32k. Only a real dwm restart reproduces the failure, so this test kills dwm.
#
# What it does: starts its own overlay, grabs the screen with GDI (which honours
# WDA_EXCLUDEFROMCAPTURE the same way capture tools do), kills dwm, waits, and grabs again.
# A frame that is almost entirely black means the overlay is being captured.
#
# Needs: run at the physical console, not over a remote session. Killing dwm needs admin,
# so a UAC prompt appears. The screen flickers once and goes dark for about 15 seconds.
# Exit codes: 0 pass, 1 fail, 2 skipped.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$target = Join-Path (Split-Path $PSScriptRoot) 'TurnOffScreen.ps1'
$WAIT_SECONDS = 8      # must exceed the re-apply interval in TurnOffScreen.ps1

function Get-DarkFraction {
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $g.Dispose()
    $dark = 0; $n = 0
    for ($x = 5; $x -lt $b.Width; $x += 37) {
        for ($y = 5; $y -lt $b.Height; $y += 37) {
            $c = $bmp.GetPixel($x, $y); $n++
            if (($c.R + $c.G + $c.B) -lt 24) { $dark++ }
        }
    }
    $bmp.Dispose()
    $dark / $n
}
function Start-Overlay {
    Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$target`"")
}
function Get-SessionDwm {
    $mine = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    (Get-Process dwm -ErrorAction SilentlyContinue | Where-Object SessionId -eq $mine | Select-Object -First 1).Id
}

if ([System.Windows.Forms.SystemInformation]::TerminalServerSession) {
    Write-Host 'SKIP: run this at the physical console, not over RDP.' -ForegroundColor Yellow
    exit 2
}
if ((Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -match 'TurnOffScreen\.ps1')) {
    Write-Host 'SKIP: overlay already running. Turn it off first.' -ForegroundColor Yellow
    exit 2
}
$baseline = Get-DarkFraction
if ($baseline -gt 0.5) {
    Write-Host ("SKIP: the desktop is already {0:P0} black, so a black capture would prove nothing." -f $baseline) -ForegroundColor Yellow
    exit 2
}

$proc = $null
$result = 1
try {
    $proc = Start-Overlay
    Start-Sleep -Seconds 4
    $before = Get-DarkFraction
    Write-Host ("overlay on, before restart: {0:P0} black" -f $before)
    if ($before -gt 0.5) { throw 'overlay is captured even before the restart' }

    $old = Get-SessionDwm
    $kill = Start-Process taskkill.exe -ArgumentList '/f', '/pid', $old -Verb RunAs -WindowStyle Hidden -PassThru -Wait
    if ($kill.ExitCode -ne 0) { throw "taskkill failed (exit $($kill.ExitCode))" }
    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        $new = Get-SessionDwm
    } while ((-not $new -or $new -eq $old) -and (Get-Date) -lt $deadline)
    if (-not $new -or $new -eq $old) { throw 'dwm did not come back within 20 s' }
    Write-Host "dwm restarted: $old -> $new"
    if ($proc.HasExited) { throw 'overlay process died with dwm' }

    Start-Sleep -Seconds $WAIT_SECONDS
    $after = Get-DarkFraction
    Write-Host ("{0} s after restart: {1:P0} black" -f $WAIT_SECONDS, $after)
    if ($after -gt 0.5) {
        Write-Host 'FAIL: the overlay is visible to screen capture after the dwm restart.' -ForegroundColor Red
    } else {
        Write-Host 'PASS: overlay still hidden from capture.' -ForegroundColor Green
        $result = 0
    }
} catch {
    Write-Host "FAIL: $_" -ForegroundColor Red
} finally {
    if ($proc -and -not $proc.HasExited) {
        # A second launch toggles the overlay off and restores brightness.
        $off = Start-Overlay
        if (-not $proc.WaitForExit(10000)) { $proc.Kill() }
        [void]$off.WaitForExit(10000)
    }
}
exit $result
