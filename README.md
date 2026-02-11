# Network Check Scripts

Use these scripts for a quick network sanity check

They basically tell you:

- Is your device connected?
- Is your room/router/wall port the problem?
- Is campus backend having a rough day?
- Is DNS being quietly unhelpful?

## Files

- `net_check_unix.sh` -> Linux/macOS
- `net_check_win.ps1` -> Windows PowerShell

## Quick Run

### Linux/macOS

```bash
bash net_check_unix.sh
```

### Windows (PowerShell)

```powershell
.\net_check_win.ps1
```

You will get a clear `RESULT` and `NEXT STEP` so you know exactly what is wrong.

## Wi-Fi Tracker Mode

Use this mode for rough signal-based direction (closer/farther) to a target router BSSID.

### Linux

```bash
bash net_check_unix.sh --track
```

Track a specific BSSID:

```bash
bash net_check_unix.sh --track AA:BB:CC:DD:EE:FF
```

### Windows

```powershell
.\net_check_win.ps1 -Track
```

Track a specific BSSID:

```powershell
.\net_check_win.ps1 -Track -TrackMac AA:BB:CC:DD:EE:FF
```

## Important Notes

- Tracker is approximate. It can get you "warm", but don't expect it to pinpoint the exact room.
- If your gateway looks like a personal router, the script will warn you.
- The script pauses at the end so you can actually read the result before the window vanishes.
- Need Linux auto-install for missing tools? Add `--auto-install`.
