if ([IntPtr]::Size -ne 8) { throw "This script requires 64-bit PowerShell." }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class NativeHelper {
    [DllImport("user32.dll")]
    public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x00000011;

    // 64-bit safe window long
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_LAYERED = 0x80000;
    public const int WS_EX_TRANSPARENT = 0x20;
    public const int WS_EX_TOOLWINDOW = 0x80;

    // Layered window attributes (fix #1: make WS_EX_LAYERED actually render)
    [DllImport("user32.dll")]
    public static extern bool SetLayeredWindowAttributes(IntPtr hWnd, uint crKey, byte bAlpha, uint dwFlags);
    public const uint LWA_ALPHA = 0x02;

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public const uint SWP_NOACTIVATE = 0x0010;

    public static void ApplyExStyles(IntPtr hWnd) {
        IntPtr exStyle = GetWindowLongPtr(hWnd, GWL_EXSTYLE);
        long val = exStyle.ToInt64();
        val |= WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW;
        SetWindowLongPtr(hWnd, GWL_EXSTYLE, new IntPtr(val));
        SetLayeredWindowAttributes(hWnd, 0, 255, LWA_ALPHA);
    }

    public static void ApplyAllFlags(IntPtr hWnd, int x, int y, int w, int h) {
        SetWindowPos(hWnd, HWND_TOPMOST, x, y, w, h, SWP_NOACTIVATE);
        SetWindowDisplayAffinity(hWnd, WDA_EXCLUDEFROMCAPTURE);
        ApplyExStyles(hWnd);
    }

    // Find overlay window by title
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    public const string OVERLAY_TITLE = "TurnOffScreen_Overlay_7F3A";
}
"@

# State machine init (before try so catch can always access it)
$script:state = [int[]]::new(1)

# Toggle: if already running, signal to stop
$script:mutex = New-Object System.Threading.Mutex($false, "Global\TurnOffScreenMutex")
$acquired = $false
$wasAbandoned = $false
try { $acquired = $script:mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $acquired = $true; $wasAbandoned = $true }
if (-not $acquired) {
    try {
        $evt = [System.Threading.EventWaitHandle]::OpenExisting("Global\TurnOffScreenEvent")
        $evt.Set()
        $evt.Dispose()
    } catch {}
    $script:mutex.Dispose()
    exit
}

try {

# Clean up stale event handle from crashed instance
if ($wasAbandoned) {
    try {
        $staleEvt = [System.Threading.EventWaitHandle]::OpenExisting("Global\TurnOffScreenEvent")
        $staleEvt.Dispose()
    } catch {}
}

$script:evt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, "Global\TurnOffScreenEvent")

# Save & dim brightness (guard against no internal display)
$script:savedBrightness = $null
$wmi = Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightness -ErrorAction SilentlyContinue
if ($wmi) {
    $script:savedBrightness = $wmi.CurrentBrightness
    # Previous crash may have left brightness at 0 — don't save that as restore target
    if ($wasAbandoned -and $script:savedBrightness -eq 0) {
        $script:savedBrightness = 80
    }
    $methods = Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue
    if ($methods) { $methods.WmiSetBrightness(1, 0) }
}

# Helper: compute bounds covering all screens
function Get-ScreenBounds {
    $screens = [System.Windows.Forms.Screen]::AllScreens
    $left   = ($screens | ForEach-Object { $_.Bounds.Left }   | Measure-Object -Minimum).Minimum
    $top    = ($screens | ForEach-Object { $_.Bounds.Top }    | Measure-Object -Minimum).Minimum
    $right  = ($screens | ForEach-Object { $_.Bounds.Right }  | Measure-Object -Maximum).Maximum
    $bottom = ($screens | ForEach-Object { $_.Bounds.Bottom } | Measure-Object -Maximum).Maximum
    @{ Left = $left; Top = $top; Width = $right - $left; Height = $bottom - $top }
}

$bounds = Get-ScreenBounds

# Fullscreen black form
$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = 'TurnOffScreen_Overlay_7F3A'
$script:form.StartPosition = 'Manual'
$script:form.Location = New-Object System.Drawing.Point($bounds.Left, $bounds.Top)
$script:form.Size = New-Object System.Drawing.Size($bounds.Width, $bounds.Height)
$script:form.BackColor = [System.Drawing.Color]::Black
$script:form.FormBorderStyle = 'None'
$script:form.TopMost = $true
$script:form.ShowInTaskbar = $false

$script:form.Add_Shown({
    [NativeHelper]::ApplyAllFlags($script:form.Handle,
        $bounds.Left, $bounds.Top, $bounds.Width, $bounds.Height)
})

$script:waitReg = [System.Threading.ThreadPool]::RegisterWaitForSingleObject(
    $script:evt,
    [System.Threading.WaitOrTimerCallback]{
        param($s, $timedOut)
        if ([System.Threading.Interlocked]::CompareExchange([ref]$script:state[0], 1, 0) -eq 0) {
            try { $script:form.BeginInvoke([Action]{ $script:form.Close() }) } catch {}
        }
    },
    $null, -1, $true  # -1 = INFINITE timeout, $true = execute once
)

# Re-apply ALL flags + resize on system events
$script:reapplyAll = {
    $b = Get-ScreenBounds
    [NativeHelper]::ApplyAllFlags($script:form.Handle, $b.Left, $b.Top, $b.Width, $b.Height)
}

$script:safeReapply = {
    if ([System.Threading.Interlocked]::CompareExchange([ref]$script:state[0], 0, 0) -eq 0) {
        try { $script:form.BeginInvoke([Action]$script:reapplyAll) } catch {}
    }
}

$script:onPowerChange = [Microsoft.Win32.PowerModeChangedEventHandler]{
    & $script:safeReapply
}
$script:onDisplayChange = [EventHandler]{
    & $script:safeReapply
}
$script:onSessionSwitch = [Microsoft.Win32.SessionSwitchEventHandler]{
    & $script:safeReapply
}

[Microsoft.Win32.SystemEvents]::add_PowerModeChanged($script:onPowerChange)
[Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged($script:onDisplayChange)
[Microsoft.Win32.SystemEvents]::add_SessionSwitch($script:onSessionSwitch)

$script:form.Add_FormClosed({
    [System.Threading.Interlocked]::Exchange([ref]$script:state[0], 1) | Out-Null
    $script:waitReg.Unregister($null)
    [Microsoft.Win32.SystemEvents]::remove_PowerModeChanged($script:onPowerChange)
    [Microsoft.Win32.SystemEvents]::remove_DisplaySettingsChanged($script:onDisplayChange)
    [Microsoft.Win32.SystemEvents]::remove_SessionSwitch($script:onSessionSwitch)
    if ($null -ne $script:savedBrightness) {
        try {
            $m = Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue
            if ($m) { $m.WmiSetBrightness(1, $script:savedBrightness) }
        } catch {}
    }
    $script:evt.Dispose()
    $script:mutex.ReleaseMutex()
    [System.Threading.Interlocked]::Exchange([ref]$script:state[0], 2) | Out-Null  # 2 = fully cleaned
    $script:mutex.Dispose()
})

[System.Windows.Forms.Application]::Run($script:form)

} catch {
    if ($null -ne $script:savedBrightness) {
        try {
            $m = Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue
            if ($m) { $m.WmiSetBrightness(1, $script:savedBrightness) }
        } catch {}
    }
    if ($script:evt) { try { $script:evt.Dispose() } catch {} }
    $s = [System.Threading.Interlocked]::Exchange([ref]$script:state[0], 2)
    # 0 = never started cleanup, 1 = cleanup started but didn't finish — either way, try releasing
    if ($s -ne 2) {
        try { $script:mutex.ReleaseMutex() } catch {}
    }
    $script:mutex.Dispose()
    throw
}
