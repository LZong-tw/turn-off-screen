param(
    [ValidateSet('Off','On','Status')][string]$Action='Off',
    [ValidateRange(0,10)][int]$DelaySeconds=2,
    [ValidateRange(1,30)][int]$ObserveSeconds=5,
    [switch]$RestoreAfterObservation
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class DisplayPowerEvent {
    public string Time;
    public string State;
}
public class DisplayPowerResult {
    public string Action;
    public bool RequestDelivered;
    public int Win32Error;
    public List<DisplayPowerEvent> Events = new List<DisplayPowerEvent>();
}
public class DesktopDisplayProbe : NativeWindow, IDisposable {
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr RegisterPowerSettingNotification(IntPtr h,ref Guid g,uint flags);
    [DllImport("user32.dll")] static extern bool UnregisterPowerSettingNotification(IntPtr h);
    [DllImport("user32.dll",SetLastError=true)] static extern IntPtr SendMessageTimeout(IntPtr h,uint message,UIntPtr command,IntPtr parameter,uint flags,uint timeout,out UIntPtr result);
    IntPtr subscription;
    Guid displayGuid = new Guid("6fe69556-704a-47a0-8f24-c28d936fda47");
    public DisplayPowerResult Result = new DisplayPowerResult();
    public DesktopDisplayProbe() {
        CreateParams cp=new CreateParams();cp.Caption="TurnOffScreen_DisplayProbe";cp.Parent=new IntPtr(-3);CreateHandle(cp);
        subscription=RegisterPowerSettingNotification(Handle,ref displayGuid,0);
        if(subscription==IntPtr.Zero)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    protected override void WndProc(ref Message m) {
        if(m.Msg==0x0218 && m.WParam.ToInt64()==0x8013 && m.LParam!=IntPtr.Zero) {
            Guid g=(Guid)Marshal.PtrToStructure(m.LParam,typeof(Guid));
            int length=Marshal.ReadInt32(m.LParam,16);
            if(g==displayGuid && length>=4) {
                int value=Marshal.ReadInt32(m.LParam,20);
                Result.Events.Add(new DisplayPowerEvent {Time=DateTimeOffset.UtcNow.ToString("o"),State=value==0?"Off":value==1?"On":value==2?"Dim":"Unknown"});
            }
        }
        base.WndProc(ref m);
    }
    public void Request(bool on) {
        UIntPtr ignored;
        IntPtr sent=SendMessageTimeout(new IntPtr(0xffff),0x0112,new UIntPtr(0xf170),new IntPtr(on?-1:2),2,1000,out ignored);
        Result.RequestDelivered=sent!=IntPtr.Zero;
        Result.Win32Error=sent==IntPtr.Zero?Marshal.GetLastWin32Error():0;
    }
    public void Dispose(){if(subscription!=IntPtr.Zero)UnregisterPowerSettingNotification(subscription);DestroyHandle();}
    public static DisplayPowerResult Run(string action,int delay,int observe,bool restore) {
        using(DesktopDisplayProbe probe=new DesktopDisplayProbe()) {
            probe.Result.Action=action;
            ApplicationContext context=new ApplicationContext();
            Timer request=new Timer();request.Interval=Math.Max(100,delay*1000);
            Timer finish=new Timer();finish.Interval=Math.Max(1000,(delay+observe)*1000);
            request.Tick+=delegate{request.Stop();if(action!="Status")probe.Request(action=="On");};
            finish.Tick+=delegate{finish.Stop();context.ExitThread();};
            request.Start();finish.Start();
            try {Application.Run(context);}
            finally {request.Dispose();finish.Dispose();context.Dispose();if(restore && action=="Off")probe.Request(true);}
            return probe.Result;
        }
    }
}
'@ -ReferencedAssemblies System.Windows.Forms
$result=[DesktopDisplayProbe]::Run($Action,$DelaySeconds,$ObserveSeconds,$RestoreAfterObservation.IsPresent)
$result|ConvertTo-Json -Depth 5
if($Action -ne 'Status' -and -not $result.RequestDelivered){exit 1}
