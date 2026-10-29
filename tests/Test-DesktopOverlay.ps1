$ErrorActionPreference='Stop'
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class OverlayBoundsProbe {
 public delegate bool Callback(IntPtr h,IntPtr p);
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
 [DllImport("user32.dll")] static extern bool EnumWindows(Callback cb,IntPtr p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] static extern int GetSystemMetrics(int n);
 public struct Rect {public int Left,Top,Right,Bottom;}
 public static bool CoversDesktop(){
  SetThreadDpiAwarenessContext(new IntPtr(-4)); bool ok=false;
  EnumWindows(delegate(IntPtr h,IntPtr p){var b=new StringBuilder(256);GetWindowText(h,b,256);if(b.ToString()=="TurnOffScreen_Overlay_7F3A"){Rect r;GetWindowRect(h,out r);ok=r.Left==GetSystemMetrics(76)&&r.Top==GetSystemMetrics(77)&&r.Right-r.Left==GetSystemMetrics(78)&&r.Bottom-r.Top==GetSystemMetrics(79);}return true;},IntPtr.Zero);return ok;
 }
}
'@
$target=Join-Path (Split-Path $PSScriptRoot) 'TurnOffScreen.ps1'
function Status { (& powershell.exe -NoProfile -STA -File $target -Action Status)|ConvertFrom-Json }
if((Status).Active){throw 'An overlay is already active; leave the user session unchanged'}
$first=$null
try {
    $first=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -STA -File `"$target`" -Action On -NoBrightness"
    Start-Sleep -Seconds 3
    if(-not (Status).Active){throw 'Desktop overlay did not start without WMI brightness'}
    if(-not [OverlayBoundsProbe]::CoversDesktop()){throw 'Overlay does not cover the full physical multi-monitor desktop'}
    $again=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -STA -File `"$target`" -Action On -NoBrightness"
    if(-not $again.WaitForExit(8000)){throw 'Second On command did not exit'}
    if(-not (Status).Active -or $first.HasExited){throw 'On toggled an already active desktop overlay off'}
    & powershell.exe -NoProfile -STA -File $target -Action Off
    if(-not $first.WaitForExit(10000)){throw 'Explicit Off did not dismiss the desktop overlay'}
    & powershell.exe -NoProfile -STA -File $target -Action Off
    if((Status).Active){throw 'Off while already off started a black overlay'}
    Write-Output 'PASS: no-brightness desktop overlay starts, repeated On stays on, and repeated Off stays off.'
}finally {
    & powershell.exe -NoProfile -STA -File $target -Action Off
    if($first -and -not $first.HasExited -and -not $first.WaitForExit(10000)){$first.Kill()}
}
