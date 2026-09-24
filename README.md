# Turn Off Screen

Software screen-off for Windows laptops where `SC_MONITORPOWER` is intercepted by vendor drivers (e.g., ASUS ExpertBook triggers lock screen instead of turning off the display).

## What it does

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
- Internal display with WMI brightness support (most laptops)

## Install

```powershell
powershell -ExecutionPolicy Bypass -File Install.ps1
```

This copies scripts to `%USERPROFILE%\Scripts` and creates a desktop shortcut.

## Usage

Run `TurnOffScreen.vbs` (double-click, shortcut, or hotkey). Run it again to restore.

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
│  ├─ Re-apply flags every 2s unconditionally      │
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

Subscribing to `PowerModeChanged` / `DisplaySettingsChanged` / `SessionSwitch` turned out not to
be enough. **Restarting `dwm.exe` drops the effect and raises none of those three events.** The
desktop window manager rebuilds its composition state, and the overlay starts being captured
again. So the flags are now also re-applied on a 2-second timer.

The re-apply is deliberately **unconditional**, and that is worth explaining before someone
tries to make it cheaper:

> Display affinity is stored in win32k, not in dwm. win32k does not restart when dwm does.
> After a dwm restart `GetWindowDisplayAffinity` still reports `WDA_EXCLUDEFROMCAPTURE`, even
> though the flag no longer does anything. A "read the current affinity, re-apply only if it
> changed" optimisation would therefore never fire — it would be a permanent no-op against the
> exact failure it was meant to fix.

The cost of getting this wrong is asymmetric: re-applying a flag that was already fine costs a
handful of microseconds twice a second, while skipping one re-apply can black out a remote
session indefinitely.

## Tests

```powershell
# with the screen-off overlay NOT running (each test starts and stops its own):
powershell -ExecutionPolicy Bypass -File tests\Test-OverlayReapply.ps1
powershell -ExecutionPolicy Bypass -File tests\Test-RemoteMode.ps1
```

Both dim and black out the local screen for a few seconds. Exit codes: `0` pass, `1` fail, `2`
skipped (an overlay was already running, or there is no WMI brightness).

`Test-OverlayReapply.ps1` makes the overlay clear its own display affinity and asserts that it comes
back within 8 seconds. The clear has to happen inside the overlay process: Windows refuses
`SetWindowDisplayAffinity` on another process's window (error 5), so the test drops a file named by
`TURNOFFSCREEN_FAKE_AFFINITY_LOSS_FLAG` and the overlay reacts to it. It clears the flag rather than
restarting dwm because restarting dwm blanks the interactive session — not something a test should
do to your machine.

`Test-RemoteMode.ps1` covers RDP: launched while remote, and going remote while the overlay is up.
A real RDP connection can't be scripted, so `TURNOFFSCREEN_FAKE_REMOTE_FLAG` makes the script treat
the session as remote.

Note what this test cannot catch: clearing the flag manually *is* visible to
`GetWindowDisplayAffinity`, so a conditional "repair only if changed" implementation would still
pass here while failing against a real dwm restart. The unconditional re-apply is an invariant the
test relies on, not one it verifies.

## Known limitations

- Chrome Remote Desktop's sharing bar, IME candidate windows, and the mouse cursor may remain faintly visible at brightness 0 (they render above the overlay in z-order; hiding them breaks remote desktop)
- Not a true DPMS off — the panel is still powered, just at minimum backlight with a black image
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
