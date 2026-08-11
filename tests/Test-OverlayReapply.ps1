# Regression test: the overlay must re-apply WDA_EXCLUDEFROMCAPTURE after it is lost.
#
# Background. The overlay hides itself from screen capture so that remote-desktop
# viewers see the real desktop instead of the black screen. Originally the flag was
# applied once at Add_Shown and re-applied only on PowerModeChanged /
# DisplaySettingsChanged / SessionSwitch. A dwm.exe restart raises none of those three,
# and it does drop the effect -- so a viewer connected over Chrome Remote Desktop got a
# black screen with no way to recover short of toggling the overlay off and on.
#
# Why this test clears the flag by hand instead of restarting dwm: restarting dwm blanks
# the interactive session and is not something a test should do to a developer's machine.
# Clearing to WDA_NONE works as a stand-in because display affinity is stored in win32k
# and GetWindowDisplayAffinity reads that real state back.
#
# The same fact is also why the fix re-applies unconditionally on a timer. After a dwm
# restart win32k still reports WDA_EXCLUDEFROMCAPTURE even though it no longer has any
# effect, so a "check, then repair if changed" guard would be a permanent no-op. This
# test cannot detect that mistake -- a manual clear IS visible to the getter, so a
# conditional implementation would still pass here. Keep the invariant in mind when
# changing TurnOffScreen.ps1.
#
# Usage: turn the screen-off overlay on first (hotkey, or run TurnOffScreen.vbs), then
# run this script. It leaves the overlay on; toggle it off yourself when done.
#
# Exit codes: 0 pass, 1 fail, 2 skipped (overlay not running).

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
    public static extern bool SetWindowDisplayAffinity(IntPtr h, uint affinity);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowDisplayAffinity(IntPtr h, out uint affinity);

    public const uint WDA_NONE = 0x00000000;
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

$hwnd = [OverlayProbe]::FindByTitle($TITLE)
if ($hwnd -eq [IntPtr]::Zero) {
    Write-Host "SKIP: overlay not found. Turn the screen off first, then re-run." -ForegroundColor Yellow
    exit 2
}
Write-Host "overlay hwnd = $hwnd"

$affinity = 0
[void][OverlayProbe]::GetWindowDisplayAffinity($hwnd, [ref]$affinity)
Write-Host ("initial affinity = 0x{0:X}" -f $affinity)
if ($affinity -ne [OverlayProbe]::WDA_EXCLUDEFROMCAPTURE) {
    Write-Host "FAIL: overlay did not have WDA_EXCLUDEFROMCAPTURE to begin with." -ForegroundColor Red
    exit 1
}

Write-Host "simulating flag loss: setting WDA_NONE"
if (-not [OverlayProbe]::SetWindowDisplayAffinity($hwnd, [OverlayProbe]::WDA_NONE)) {
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Host "FAIL: could not clear affinity (win32 error $err)" -ForegroundColor Red
    exit 1
}

[void][OverlayProbe]::GetWindowDisplayAffinity($hwnd, [ref]$affinity)
if ($affinity -eq [OverlayProbe]::WDA_EXCLUDEFROMCAPTURE) {
    Write-Host "FAIL: the clear did not take effect, so this test proves nothing." -ForegroundColor Red
    exit 1
}
Write-Host ("cleared, now 0x{0:X}" -f $affinity)

Write-Host "waiting up to $WAIT_SECONDS s for the overlay to restore it..."
$deadline = (Get-Date).AddSeconds($WAIT_SECONDS)
$restored = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    [void][OverlayProbe]::GetWindowDisplayAffinity($hwnd, [ref]$affinity)
    if ($affinity -eq [OverlayProbe]::WDA_EXCLUDEFROMCAPTURE) { $restored = $true; break }
}

if ($restored) {
    Write-Host ("PASS: flag restored automatically (0x{0:X})" -f $affinity) -ForegroundColor Green
    exit 0
}

Write-Host ("FAIL: not restored within {0} s, affinity still 0x{1:X}." -f $WAIT_SECONDS, $affinity) -ForegroundColor Red
Write-Host "The overlay is currently visible to screen capture. Toggle it off and on to restore protection." -ForegroundColor Yellow
exit 1
