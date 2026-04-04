# Turn Off Screen

Software screen-off for Windows laptops where `SC_MONITORPOWER` is intercepted by vendor drivers (e.g., ASUS ExpertBook triggers lock screen instead of turning off the display).

## What it does

- Sets display brightness to 0 via WMI (saves power)
- Shows a fullscreen black overlay window (prevents burn-in)
- Overlay is invisible to screen capture (`WDA_EXCLUDEFROMCAPTURE`) — Chrome Remote Desktop and other remote tools see the normal desktop
- Overlay is click-through (`WS_EX_TRANSPARENT`) — remote desktop input works normally
- Toggle: run once to activate, run again to deactivate and restore brightness

## Requirements

- Windows 10 2004+ or Windows 11
- 64-bit PowerShell 5.1 (ships with Windows)
- Internal display with WMI brightness support (most laptops)

## Install

```powershell
powershell -ExecutionPolicy Bypass -File Install.ps1
```

This copies scripts to `%USERPROFILE%\Scripts` and creates a desktop shortcut.

## Usage

Run `TurnOffScreen.vbs` (double-click, shortcut, or hotkey). Run it again to restore.

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
│  │  ├─ WDA_EXCLUDEFROMCAPTURE (invisible to RDP) │
│  │  ├─ WS_EX_TRANSPARENT (click-through)         │
│  │  └─ WS_EX_TOOLWINDOW (hidden from Alt+Tab)   │
│  ├─ Subscribe to system events (power, display,  │
│  │   session) to re-apply flags if reset          │
│  └─ Wait for dismiss signal                      │
│                                                  │
│  2nd run                                         │
│  ├─ Detect mutex held → signal EventWaitHandle   │
│  └─ 1st instance closes overlay, restores bright │
└──────────────────────────────────────────────────┘
```

## Known limitations

- Chrome Remote Desktop's sharing bar, IME candidate windows, and the mouse cursor may remain faintly visible at brightness 0 (they render above the overlay in z-order; hiding them breaks remote desktop)
- Not a true DPMS off — the panel is still powered, just at minimum backlight with a black image
- 64-bit PowerShell only (`GetWindowLongPtrW` is not exported on 32-bit)

## Why not just use SC_MONITORPOWER?

Some vendor drivers (notably ASUS ExpertBook's `ATKWMIACPIIO`) intercept `WM_SYSCOMMAND` / `SC_MONITORPOWER` and force a lock screen instead of turning off the display. This script bypasses that entirely by not using power management APIs at all.

Tested alternatives that don't work on affected hardware:
- `SendMessage(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2)` — intercepted, triggers lock
- NirCmd `monitor off` — uses the same API internally
- DDC/CI `SetVCPFeature` — not supported on internal laptop panels
- `MagSetFullscreenColorEffect` — also affects screen capture, breaking remote desktop

## License

MIT
