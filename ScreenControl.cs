using System;
using System.IO;
using System.Drawing;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
public class ScreenControl : Form {
    [DllImport("user32.dll",SetLastError=true)]static extern IntPtr RegisterPowerSettingNotification(IntPtr h,ref Guid g,uint f);
    [DllImport("user32.dll")]static extern bool UnregisterPowerSettingNotification(IntPtr h);
    IntPtr notification; Label status=new Label(); System.Windows.Forms.Timer timer=new System.Windows.Forms.Timer();
    string root=AppDomain.CurrentDomain.BaseDirectory;
    public ScreenControl(){
        Text="螢幕控制";ClientSize=new Size(650,350);FormBorderStyle=FormBorderStyle.FixedDialog;MaximizeBox=false;
        StartPosition=FormStartPosition.CenterScreen;Font=new Font("Microsoft JhengHei UI",10);BackColor=Color.FromArgb(245,247,250);
        Label title=new Label();title.Text="讓電腦工作，讓螢幕休息";title.Font=new Font(Font.FontFamily,18,FontStyle.Bold);title.SetBounds(25,20,600,38);Controls.Add(title);
        Label hint=new Label();hint.Text="兩種模式都不會讓電腦睡眠，也不影響 runner。";hint.SetBounds(27,69,590,28);Controls.Add(hint);
        Button native=Button("真正關屏",27,112),night=Button("夜間黑幕",228,112),restore=Button("恢復螢幕",429,112);
        native.Click+=delegate{Launch("MonitorPower.ps1","-Action Off -DelaySeconds 2 -ObserveSeconds 5");};
        night.Click+=delegate{Launch("TurnOffScreen.ps1","-Action On");};restore.Click+=delegate{Launch("RestoreScreen.ps1","");};
        Label detail=new Label();detail.Text="真正關屏：螢幕進入待機，移動滑鼠或按鍵可喚亮。\r\n夜間黑幕：保持黑色遮罩，遠端畫面可維持正常；不等於斷電。\r\n夜間黑幕請按 Ctrl + Alt + M，或按「恢復螢幕」解除。";detail.SetBounds(27,175,595,85);Controls.Add(detail);
        status.SetBounds(27,275,595,50);Controls.Add(status);
        timer.Interval=1000;timer.Tick+=delegate{RefreshOverlay();};Shown+=delegate{timer.Start();RefreshOverlay();};
        FormClosed+=delegate{timer.Dispose();if(notification!=IntPtr.Zero)UnregisterPowerSettingNotification(notification);};
    }
    Button Button(string text,int x,int y){Button b=new Button();b.Text=text;b.SetBounds(x,y,185,43);b.BackColor=Color.White;b.FlatStyle=FlatStyle.Flat;Controls.Add(b);return b;}
    void Launch(string file,string args){try{string script=Path.Combine(root,file);Process.Start(new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe"),"-NoProfile -STA -WindowStyle Hidden -File \""+script+"\" "+args){UseShellExecute=false,CreateNoWindow=true});}catch(Exception e){MessageBox.Show(e.Message,"無法執行");}}
    string display="等待 Windows 回報";
    protected override void OnHandleCreated(EventArgs e){base.OnHandleCreated(e);Guid g=new Guid("6fe69556-704a-47a0-8f24-c28d936fda47");notification=RegisterPowerSettingNotification(Handle,ref g,0);if(notification==IntPtr.Zero)display="無法讀取 Windows 狀態";}
    protected override void WndProc(ref Message m){if(m.Msg==0x218&&m.WParam.ToInt64()==0x8013&&m.LParam!=IntPtr.Zero){Guid g=(Guid)Marshal.PtrToStructure(m.LParam,typeof(Guid));if(g==new Guid("6fe69556-704a-47a0-8f24-c28d936fda47")&&Marshal.ReadInt32(m.LParam,16)>=4){int v=Marshal.ReadInt32(m.LParam,20);display=v==0?"已關閉":v==1?"亮起":v==2?"調暗":"未知";}}base.WndProc(ref m);}
    bool OverlayOn(){try{using(Mutex m=Mutex.OpenExisting(@"Global\TurnOffScreenMutex")){try{if(m.WaitOne(0)){m.ReleaseMutex();return false;}return true;}catch(AbandonedMutexException){m.ReleaseMutex();return false;}}}catch(WaitHandleCannotBeOpenedException){return false;}}
    void RefreshOverlay(){status.Text="Windows 顯示狀態："+display+"　｜　夜間黑幕："+(OverlayOn()?"啟用中":"未啟用")+"\r\n關閉這個視窗不會解除黑幕；Ctrl + Alt + M 仍可恢復。";}
    [STAThread]public static void Main(){Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);Application.Run(new ScreenControl());}
}
