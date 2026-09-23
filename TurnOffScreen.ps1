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

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);
    public const int SM_REMOTESESSION = 0x1000;
    public static bool IsRemoteSession() {
        return GetSystemMetrics(SM_REMOTESESSION) != 0;
    }

    [DllImport("kernel32.dll")]
    public static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("kernel32.dll")]
    public static extern bool ProcessIdToSessionId(uint pid, out uint sessionId);

    // Test seam: while this file exists, the session is treated as remote.
    public static string FakeRemoteFlag = null;

    // 1 = our session is not on the physical console (RDP, connected or disconnected),
    // 0 = it is, -1 = unknown (the console is mid-switch). A disconnected RDP session is
    // not "remote" to SM_REMOTESESSION, which is why the session ids are compared too.
    public static int ConsoleState() {
        if (FakeRemoteFlag != null && System.IO.File.Exists(FakeRemoteFlag)) return 1;
        if (IsRemoteSession()) return 1;
        uint console = WTSGetActiveConsoleSessionId();
        if (console == 0xFFFFFFFF) return -1;
        uint mine;
        if (!ProcessIdToSessionId((uint)System.Diagnostics.Process.GetCurrentProcess().Id, out mine)) return -1;
        return mine == console ? 0 : 1;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
"@

if ($env:TURNOFFSCREEN_FAKE_REMOTE_FLAG) { [NativeHelper]::FakeRemoteFlag = $env:TURNOFFSCREEN_FAKE_REMOTE_FLAG }

$script:logFile = Join-Path $env:LOCALAPPDATA 'TurnOffScreen\TurnOffScreen.log'
function Write-Log([string]$msg) {
    try {
        $dir = Split-Path $script:logFile
        if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        if ((Test-Path $script:logFile) -and (Get-Item $script:logFile).Length -gt 256KB) {
            Move-Item $script:logFile "$script:logFile.old" -Force
        }
        Add-Content -Path $script:logFile -Value ("{0} [{1}] {2}" -f (Get-Date -Format s), $PID, $msg) -Encoding UTF8
    } catch {}
}

function Set-PanelBrightness([int]$level) {
    try {
        $m = Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue
        if (-not $m) { Write-Log "brightness -> ${level}: WmiMonitorBrightnessMethods unavailable"; return }
        [void]$m.WmiSetBrightness(1, $level)
        Write-Log "brightness -> $level"
    } catch { Write-Log "brightness -> $level failed: $_" }
}

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
$script:statusFile = Join-Path $env:TEMP 'TurnOffScreen.status'

# RDP remotes the composed session, so WDA_EXCLUDEFROMCAPTURE cannot hide the overlay
# from an RDP viewer. While the session is away from the console we run in "remote mode":
# overlay hidden, brightness kept at 0. The physical panel then shows the console lock
# screen, which this session cannot draw over, so dim is as dark as it gets.
$script:remoteMode = $false
$script:startRemote = ([NativeHelper]::ConsoleState() -eq 1)
Write-Log ("start: remote={0} SM_REMOTESESSION={1} abandoned={2}" -f $script:startRemote, [NativeHelper]::IsRemoteSession(), $wasAbandoned)

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
    Write-Log "saved brightness $brightness, dimmed to 0"
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

# Launched from inside RDP: never let the black form paint in the remote session.
if ($script:startRemote) { $script:form.Opacity = 0 }

$script:form.Add_Shown({
    if ($script:startRemote) {
        & $script:enterRemoteMode
        return
    }
    [NativeHelper]::ApplyAllFlags($script:form.Handle,
        $bounds.Left, $bounds.Top, $bounds.Width, $bounds.Height)
})

# Tray icon is NOT capture-excluded, so Chrome Remote Desktop can see it.
$script:iconBmp = New-Object System.Drawing.Bitmap 16, 16
$g = [System.Drawing.Graphics]::FromImage($script:iconBmp)
$g.Clear([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
$g.FillEllipse([System.Drawing.Brushes]::Black, 1, 1, 13, 13)
$g.DrawEllipse([System.Drawing.Pens]::White, 1, 1, 13, 13)
$g.Dispose()
$script:iconHandle = $script:iconBmp.GetHicon()
$script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:notifyIcon.Icon = [System.Drawing.Icon]::FromHandle($script:iconHandle)
$script:notifyIcon.Text = 'Turn Off Screen: ON'
$script:notifyIcon.Visible = $true
$script:notifyMenu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$script:notifyMenu.Items.Add('Restore screen', $null, { $script:evt.Set() })
$script:notifyIcon.ContextMenuStrip = $script:notifyMenu
$script:notifyIcon.Add_MouseUp({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:evt.Set() }
})
Set-Content -Path $script:statusFile -Value 'on' -Encoding ASCII

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

$script:requestDismiss = {
    $script:evt.Set()
}

$script:enterRemoteMode = {
    $script:remoteMode = $true
    $script:form.Hide()
    Set-PanelBrightness 0
    $script:notifyIcon.Text = 'Turn Off Screen: ON (remote)'
    Write-Log 'entered remote mode'
}

$script:reapplyAll = {
    if (-not [NativeHelper]::IsRunning()) { return }
    $state = [NativeHelper]::ConsoleState()
    if ($state -eq 1) {
        if (-not $script:remoteMode) { & $script:enterRemoteMode }
        return
    }
    if ($script:remoteMode) {
        # Back on the physical console means someone signed in at the machine.
        if ($state -eq 0) {
            Write-Log 'session back on console, dismissing'
            & $script:requestDismiss
        }
        return
    }
    $b = Get-ScreenBounds
    [NativeHelper]::ApplyAllFlags($script:form.Handle, $b.Left, $b.Top, $b.Width, $b.Height)
}

# The system events below don't cover everything that can drop the flags. A dwm.exe
# restart raises none of them, and it silently un-hides the overlay from screen capture:
# the desktop window manager rebuilds its composition state, but WDA_EXCLUDEFROMCAPTURE
# lives in win32k, which does NOT restart with dwm. The flag is still recorded, it just
# stops taking effect. Remote viewers then see a black screen.
#
# That last detail is why this must re-apply unconditionally rather than check first:
# GetWindowDisplayAffinity keeps reporting WDA_EXCLUDEFROMCAPTURE after a dwm restart,
# so any "read it, patch it if it changed" guard would never fire. Don't add one.
$script:reapplyTimer = New-Object System.Windows.Forms.Timer
$script:reapplyTimer.Interval = 2000
$script:reapplyTimer.Add_Tick($script:reapplyAll)
$script:reapplyTimer.Start()

$script:onPowerChange = [Microsoft.Win32.PowerModeChangedEventHandler]{
    try { $script:form.BeginInvoke([Action]$script:reapplyAll) } catch {}
}
$script:onDisplayChange = [EventHandler]{
    try { $script:form.BeginInvoke([Action]$script:reapplyAll) } catch {}
}
$script:onSessionSwitch = [Microsoft.Win32.SessionSwitchEventHandler]{
    param($sender, $e)
    try { Write-Log "SessionSwitch $($e.Reason) consoleState=$([NativeHelper]::ConsoleState())" } catch {}
    try { $script:form.BeginInvoke([Action]$script:reapplyAll) } catch {}
}

[Microsoft.Win32.SystemEvents]::add_PowerModeChanged($script:onPowerChange)
[Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged($script:onDisplayChange)
[Microsoft.Win32.SystemEvents]::add_SessionSwitch($script:onSessionSwitch)

$script:form.Add_FormClosed({
    [NativeHelper]::TryBeginClose()
    $script:dismissTimer.Stop()
    $script:dismissTimer.Dispose()
    $script:reapplyTimer.Stop()
    $script:reapplyTimer.Dispose()
    if ($script:notifyIcon) {
        $script:notifyIcon.Visible = $false
        $script:notifyIcon.Dispose()
    }
    if ($script:notifyMenu) { $script:notifyMenu.Dispose() }
    if ($script:iconHandle -and $script:iconHandle -ne [IntPtr]::Zero) {
        [void][NativeHelper]::DestroyIcon($script:iconHandle)
    }
    if ($script:iconBmp) { $script:iconBmp.Dispose() }
    if ($script:statusFile) { Set-Content -Path $script:statusFile -Value 'off' -Encoding ASCII }
    $val = [NativeHelper]::SavedBrightness
    if ($val -gt 0) { Set-PanelBrightness $val }
    Write-Log 'dismissed'
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
    Write-Log "crashed: $_"
    $val = [NativeHelper]::SavedBrightness
    if ($val -gt 0) { Set-PanelBrightness $val }
    if ($script:evt) { try { $script:evt.Dispose() } catch {} }
    try { $script:mutex.ReleaseMutex() } catch {}
    [NativeHelper]::SetCleaned()
    $script:mutex.Dispose()
    throw
}
