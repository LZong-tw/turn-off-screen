# Turn Off Screen

Two screen-off modes for Windows desktops and laptops: native display standby, and a persistent black overlay for hardware where `SC_MONITORPOWER` is intercepted by vendor drivers (e.g., ASUS ExpertBook triggers lock screen instead of turning off the display).

## Desktop control window

Install creates a **螢幕控制** (Screen Control) shortcut with three actions:

| Action | Effect | Restore |
|---|---|---|
| 真正關屏 | Requests native display standby after two seconds; the computer keeps working | Move the mouse, press a key, or use Restore |
| 夜間黑幕 | Keeps a black overlay on the local desktop; dims internal panels when WMI supports it | Restore button or **Ctrl+Alt+M** |
| 恢復螢幕 | Explicitly dismisses the overlay and requests native display power on | Idempotent; safe to repeat |

The window shows Windows display-power notifications separately from overlay state. A successful request is **not** treated as proof that physical monitors turned off: `MonitorPower.ps1` records actual Windows `On`/`Off`/`Dim` notifications, and hardware still needs a physical check. The native mode was physically verified on a three-external-monitor desktop.

The overlay remains active if the control window closes. The overlay process directly registers **Ctrl+Alt+M** to restore, so this key does not depend on Explorer's desktop-shortcut registration or keeping the control window open. If another app owns the combination, a notification and log entry report the conflict; use the tray restore action or the **恢復螢幕** desktop shortcut instead.

PowerToys Awake can prevent automatic display-off when **Keep screen on** is enabled. Keep Awake enabled if desired, but disable that separate display option; it overrides the display timeout without changing the power plan. This utility does not silently change PowerToys settings.

## What overlay mode does

- Sets display brightness to 0 via WMI (saves power)
- Shows a fullscreen black overlay window (prevents burn-in)
- Overlay is invisible to screen capture (`WDA_EXCLUDEFROMCAPTURE`) — Chrome Remote Desktop sees the normal desktop
- Overlay is click-through (`WS_EX_TRANSPARENT`) — remote desktop input works normally
- A tray icon (not capture-excluded) shows that the overlay is ON; click it or run the script again to restore
- A notification pops up when the screen turns off, when an RDP session connects while it is off, and when it is restored (Focus Assist may suppress it)
- RDP is a composed session, not a capture API, so while you are connected over RDP the overlay hides itself but brightness stays at 0; it turns off once someone signs in at the laptop itself
- Toggle: run once to activate, run again to deactivate and restore brightness

## Requirements

- Windows 10 2004+ or Windows 11
- 64-bit PowerShell 5.1 (ships with Windows)
- WMI brightness support is optional for the overlay; external monitors use the black image without brightness control
- Native display standby depends on Windows, GPU and monitor support; use the overlay on affected ASUS laptops

## Install

```powershell
powershell -ExecutionPolicy Bypass -File Install.ps1
```

This copies scripts to `%USERPROFILE%\Scripts` and creates a desktop shortcut.

It also builds the small control window with Windows' built-in .NET Framework C# compiler. Close the existing control window before reinstalling. To place the utility on another drive:

```powershell
powershell -NoProfile -File Install.ps1 -TargetDirectory G:\ScreenControl
```

## Usage

Run `TurnOffScreen.vbs` (double-click, shortcut, or hotkey). Run it again to restore.

The original toggle behaviour remains the default. For explicit, repeatable operations:

```powershell
powershell -NoProfile -STA -File TurnOffScreen.ps1 -Action On
powershell -NoProfile -STA -File TurnOffScreen.ps1 -Action Off
powershell -NoProfile -STA -File TurnOffScreen.ps1 -Action Status
powershell -NoProfile -STA -File MonitorPower.ps1 -Action Off
powershell -NoProfile -STA -File MonitorPower.ps1 -Action Status -DelaySeconds 0 -ObserveSeconds 2
powershell -NoProfile -STA -File RestoreScreen.ps1
```

`-NoBrightness` on the overlay forces desktop-style operation without changing a panel's brightness. This is also used by the desktop regression test. Explicit `On` never toggles an existing overlay off, and explicit `Off` never starts an overlay.

### How to tell from remote that it is on

The black overlay is hidden from screen capture, so Chrome Remote Desktop will not show a black screen. Look at the system tray instead:

| What you see | Meaning |
|---|---|
| Black-circle tray icon, tooltip `Turn Off Screen: ON` | Overlay is on. Local panel is black. |
| No tray icon | Overlay is off. |
| `%TEMP%\TurnOffScreen.status` reads `on` / `off` | Same signal, for scripts. |

Click the tray icon (or its `Restore screen` menu) to turn it off from remote.

Windows App / RDP: the overlay hides itself while the session is remote (you see the desktop), but the panel stays at brightness 0 and the tray icon tooltip reads `Turn Off Screen: ON (remote)`. It also works when started from inside RDP. It restores brightness and exits when someone signs in at the physical console, or when you toggle it off.

### Hotkey binding

| Method | Steps |
|--------|-------|
| **ASUS ExpertWidget** | Bind `TurnOffScreen.vbs` to Fn+F10/F11/F12 |
| **Desktop shortcut** | Right-click shortcut > Properties > Shortcut key |
| **AutoHotkey** | `^!m::Run "path\to\TurnOffScreen.vbs"` |

## How it works

```
┌──────────────────────────────────────────────────┐
│  1st run                                         │
│  ├─ Acquire named mutex (single instance)        │
│  ├─ Save current brightness, set to 0            │
│  ├─ Create fullscreen black WinForms overlay     │
│  │  ├─ WDA_EXCLUDEFROMCAPTURE (hidden from CRD)  │
│  │  ├─ tray icon (visible to CRD = overlay ON)   │
│  │  ├─ WS_EX_TRANSPARENT (click-through)         │
│  │  └─ WS_EX_TOOLWINDOW (hidden from Alt+Tab)   │
│  ├─ Subscribe to system events (power, display,  │
│  │   session) to re-apply flags if reset          │
│  ├─ Every 2s: re-apply flags; if dwm.exe was     │
│  │   restarted, clear and re-set capture flag     │
│  │   (see "Keeping the overlay hidden" below)     │
│  └─ Wait for dismiss signal                      │
│                                                  │
│  2nd run                                         │
│  ├─ Detect mutex held → signal EventWaitHandle   │
│  └─ 1st instance closes overlay, restores bright │
└──────────────────────────────────────────────────┘
```

## Keeping the overlay hidden

The overlay's whole trick is `WDA_EXCLUDEFROMCAPTURE`: the panel shows black, but anything
capturing the screen — Chrome Remote Desktop, Teams, OBS — is handed the real desktop. **RDP is
not a capture API**; it remotes the composed session, so the same overlay would black out an
RDP viewer. While the session is away from the physical console the overlay hides and only the
brightness stays down; the console shows its own lock screen, which this session cannot draw over.

If the capture flag stops taking effect, a Chrome Remote Desktop viewer sees a black screen and,
since the overlay is click-through and hidden from Alt+Tab, has no obvious way to get rid of it.

The way it stops taking effect in practice is a **`dwm.exe` restart**. dwm crashes under memory
exhaustion (`0xc00001ad`) and Windows restarts it; that raises none of `PowerModeChanged` /
`DisplaySettingsChanged` / `SessionSwitch`, and afterwards the overlay is captured again.

> Display affinity is stored in win32k, not in dwm, and win32k does not restart when dwm does.
> After a dwm restart `GetWindowDisplayAffinity` still reports `WDA_EXCLUDEFROMCAPTURE`, even
> though the flag no longer does anything. Setting the same value again is a no-op: an earlier
> version re-applied it every 2 seconds and the overlay stayed captured indefinitely
> (`tests/Test-DwmRestart.ps1` reproduced this with a real dwm restart).

What works is clearing the flag and setting it again. The overlay watches its session's dwm
process id on a 2-second timer and does exactly that when it changes, logging
`dwm restarted (old -> new)`.

## Tests

Desktop/native tests (briefly blank the local displays and restore them automatically):

```powershell
powershell -NoProfile -STA -File tests\Test-NativeDisplay.ps1
powershell -NoProfile -STA -File tests\Test-DesktopOverlay.ps1
```

The native test requires a real Windows `Off` notification, not just successful API delivery. The desktop overlay test covers operation without WMI brightness and repeated explicit On/Off calls. It refuses to disturb an overlay already running before the test.

On the validated Windows 11 desktop, native standby and wake were confirmed on all three external displays. The control window's night/restore actions and the directly registered Ctrl+Alt+M hotkey were also exercised. An Explorer shortcut hotkey had not fired reliably there, so restore is registered by the overlay process itself.

```powershell
# with the screen-off overlay NOT running (each test starts and stops its own):
powershell -ExecutionPolicy Bypass -File tests\Test-OverlayReapply.ps1
powershell -ExecutionPolicy Bypass -File tests\Test-RemoteMode.ps1
# at the physical console; shows a UAC prompt to kill dwm.exe:
powershell -ExecutionPolicy Bypass -File tests\Test-DwmRestart.ps1
```

All of them dim and black out the local screen for a few seconds. Exit codes: `0` pass, `1` fail, `2`
skipped (an overlay was already running, or there is no WMI brightness).

`Test-OverlayReapply.ps1` makes the overlay clear its own display affinity and asserts that it comes
back within 8 seconds. The clear has to happen inside the overlay process: Windows refuses
`SetWindowDisplayAffinity` on another process's window (error 5), so the test drops a file named by
`TURNOFFSCREEN_FAKE_AFFINITY_LOSS_FLAG` and the overlay reacts to it. A manual clear *is* visible
to win32k, so this test cannot reproduce the dwm-restart failure; `Test-DwmRestart.ps1` does.

`Test-DwmRestart.ps1` kills dwm for real and checks a GDI screen grab: the overlay must not show up
as a black frame 8 seconds after the restart. The screen flickers once.

`Test-RemoteMode.ps1` covers RDP: launched while remote, and going remote while the overlay is up.
A real RDP connection can't be scripted, so `TURNOFFSCREEN_FAKE_REMOTE_FLAG` makes the script treat
the session as remote.

## Known limitations

- Chrome Remote Desktop's sharing bar, IME candidate windows, and the mouse cursor may remain faintly visible at brightness 0 (they render above the overlay in z-order; hiding them breaks remote desktop)
- Overlay mode is not true DPMS off: the panel stays powered, and external-monitor backlights are not dimmed by WMI. Native mode requests display standby instead.
- 64-bit PowerShell only (`GetWindowLongPtrW` is not exported on 32-bit)
- Windows App / native RDP cannot hide this overlay the way Chrome Remote Desktop can; over RDP only the brightness is kept at 0

## Why not just use SC_MONITORPOWER?

Some vendor drivers (notably ASUS ExpertBook's `ATKWMIACPIIO`) intercept `WM_SYSCOMMAND` / `SC_MONITORPOWER` and force a lock screen instead of turning off the display. This script bypasses that entirely by not using power management APIs at all.

Tested alternatives that don't work on affected hardware:
- `SendMessage(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2)` — intercepted, triggers lock
- NirCmd `monitor off` — uses the same API internally
- DDC/CI `SetVCPFeature` — not supported on internal laptop panels
- `MagSetFullscreenColorEffect` — also affects screen capture, breaking remote desktop

## License

MIT
