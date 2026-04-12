if ([IntPtr]::Size -ne 8) { throw "This script requires 64-bit PowerShell." }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Threading;

public class NativeHelper {
    // State machine: 0=running, 1=closing, 2=cleaned
    private static int _state = 0;
    public static int SavedBrightness = -1;

    public static bool TryBeginClose() {
        return Interlocked.CompareExchange(ref _state, 1, 0) == 0;
    }

    public static bool IsRunning() {
        return Interlocked.CompareExchange(ref _state, 0, 0) == 0;
    }

    public static void SetCleaned() {
        Interlocked.Exchange(ref _state, 2);
    }

    [DllImport("user32.dll")]
    public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x00000011;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_LAYERED = 0x80000;
    public const int WS_EX_TRANSPARENT = 0x20;
    public const int WS_EX_TOOLWINDOW = 0x80;

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

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    public const string OVERLAY_TITLE = "TurnOffScreen_Overlay_7F3A";
}
"@

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

if ($wasAbandoned) {
    try {
        $staleEvt = [System.Threading.EventWaitHandle]::OpenExisting("Global\TurnOffScreenEvent")
        $staleEvt.Dispose()
    } catch {}
}

$script:evt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, "Global\TurnOffScreenEvent")

# Save & dim brightness
$brightnessFile = Join-Path $env:TEMP "TurnOffScreen_Brightness.txt"
$wmi = Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightness -ErrorAction SilentlyContinue
if ($wmi) {
    $brightness = [int]$wmi.CurrentBrightness
    if ($brightness -eq 0) {
        if (Test-Path $brightnessFile) {
            try { $brightness = [int](Get-Content $brightnessFile) } catch { $brightness = 80 }
        } else { $brightness = 80 }
        if ($brightness -le 0) { $brightness = 80 }
    }
    [NativeHelper]::SavedBrightness = $brightness
    [IO.File]::WriteAllText($brightnessFile, $brightness.ToString())
    $methods = Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue
    if ($methods) { $methods.WmiSetBrightness(1, 0) }
}

function Get-ScreenBounds {
    $screens = [System.Windows.Forms.Screen]::AllScreens
    $left   = ($screens | ForEach-Object { $_.Bounds.Left }   | Measure-Object -Minimum).Minimum
    $top    = ($screens | ForEach-Object { $_.Bounds.Top }    | Measure-Object -Minimum).Minimum
    $right  = ($screens | ForEach-Object { $_.Bounds.Right }  | Measure-Object -Maximum).Maximum
    $bottom = ($screens | ForEach-Object { $_.Bounds.Bottom } | Measure-Object -Maximum).Maximum
    @{ Left = $left; Top = $top; Width = $right - $left; Height = $bottom - $top }
}

$bounds = Get-ScreenBounds

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

# Dismiss via UI-thread Timer polling the event (BeginInvoke from ThreadPool breaks $script: scope)
$script:dismissTimer = New-Object System.Windows.Forms.Timer
$script:dismissTimer.Interval = 200
$script:dismissTimer.Add_Tick({
    if ($script:evt.WaitOne(0)) {
        $script:dismissTimer.Stop()
        if ([NativeHelper]::TryBeginClose()) {
            $script:form.Close()
        }
    }
})
$script:dismissTimer.Start()

# Re-apply flags on system events
$script:reapplyAll = {
    if ([NativeHelper]::IsRunning()) {
        $b = Get-ScreenBounds
        [NativeHelper]::ApplyAllFlags($script:form.Handle, $b.Left, $b.Top, $b.Width, $b.Height)
    }
}

$script:onPowerChange = [Microsoft.Win32.PowerModeChangedEventHandler]{
    try { $script:form.BeginInvoke([Action]$script:reapplyAll) } catch {}
}
$script:onDisplayChange = [EventHandler]{
    try { $script:form.BeginInvoke([Action]$script:reapplyAll) } catch {}
}
$script:onSessionSwitch = [Microsoft.Win32.SessionSwitchEventHandler]{
    try { $script:form.BeginInvoke([Action]$script:reapplyAll) } catch {}
}

[Microsoft.Win32.SystemEvents]::add_PowerModeChanged($script:onPowerChange)
[Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged($script:onDisplayChange)
[Microsoft.Win32.SystemEvents]::add_SessionSwitch($script:onSessionSwitch)

$script:form.Add_FormClosed({
    [NativeHelper]::TryBeginClose()
    $script:dismissTimer.Stop()
    $script:dismissTimer.Dispose()
    # Restore brightness
    $val = [NativeHelper]::SavedBrightness
    if ($val -gt 0) {
        try {
            $m = Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue
            if ($m) { $m.WmiSetBrightness(1, $val) }
        } catch {}
    }
    try { [Microsoft.Win32.SystemEvents]::remove_PowerModeChanged($script:onPowerChange) } catch {}
    try { [Microsoft.Win32.SystemEvents]::remove_DisplaySettingsChanged($script:onDisplayChange) } catch {}
    try { [Microsoft.Win32.SystemEvents]::remove_SessionSwitch($script:onSessionSwitch) } catch {}
    try { $script:evt.Dispose() } catch {}
    try { $script:mutex.ReleaseMutex() } catch {}
    [NativeHelper]::SetCleaned()
    try { $script:mutex.Dispose() } catch {}
})

[System.Windows.Forms.Application]::Run($script:form)

} catch {
    $val = [NativeHelper]::SavedBrightness
    if ($val -gt 0) {
        try {
            $m = Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue
            if ($m) { $m.WmiSetBrightness(1, $val) }
        } catch {}
    }
    if ($script:evt) { try { $script:evt.Dispose() } catch {} }
    try { $script:mutex.ReleaseMutex() } catch {}
    [NativeHelper]::SetCleaned()
    $script:mutex.Dispose()
    throw
}
