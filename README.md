# Dropbox ContextMenuBlocker

**Permanently remove Dropbox right-click context menu entries on Windows — without playing whack-a-mole with registry keys that revert on every update.**

<img width="637" height="755" alt="image" src="https://github.com/user-attachments/assets/ca5b7a42-c3a7-4ff4-83f5-bcb49843190c" />

---

## The Problem

Dropbox registers multiple shell extension CLSIDs that inject entries into your Windows right-click context menu. The commonly recommended fix — manually deleting those registry keys — doesn't stick. Dropbox silently rewrites them on every update.

## The Solution

Instead of fighting Dropbox's own registry keys, this script uses **Windows' built-in shell extension blocking mechanism**: the per-user `HKCU:\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked` key. This is a Microsoft-sanctioned method that Windows itself enforces. Dropbox doesn't touch it because it's not theirs to manage.

- ✅ Reads Dropbox's `AppxManifest.xml` to find the correct CLSIDs automatically — no hardcoding
- ✅ Survives Dropbox updates (tested 2+ months across three machines through multiple updates)
- ✅ Fully reversible — one command to unblock everything
- ✅ Interactive menu **or** silent command-line mode for automation
- ✅ Only touches a single, user-scoped registry key. No system-wide changes.

---

## Requirements

- Windows 10 (version 1903+) or Windows 11
- PowerShell 5.1+ (PowerShell 7 recommended)
- Dropbox installed via the Microsoft Store (UWP/MSIX package)

---

## Usage

### Interactive Mode

```powershell
.\ContextMenuBlocker.ps1
```

Launches a menu with options to block, unblock, selectively manage entries, export/import state, and more.

### Silent / Automation Mode

```powershell
# Block all context menu entries (no prompts)
.\ContextMenuBlocker.ps1 -BlockAll -NoPrompt

# Unblock all context menu entries (no prompts)
.\ContextMenuBlocker.ps1 -UnblockAll -NoPrompt

# Block without restarting Explorer
.\ContextMenuBlocker.ps1 -BlockAll -NoPrompt -NoRestartExplorer
```

> **Note:** The script will prompt for administrator privileges when it runs. This is required to read the protected `C:\Program Files\WindowsApps` folder where Dropbox's manifest is stored. The elevation prompt is standard and expected.

---

## What It Changes

| Location | What happens |
|----------|-------------|
| `HKCU:\...\Shell Extensions\Blocked` | CLSID values added (blocking) or removed (unblocking) |
| `~\ContextMenuBlocker.log` | Optional activity log (user profile folder) |
| `~\ContextMenuBlocker_Backups\` | Optional JSON state backups (user profile folder) |

**Nothing else is modified.** No HKLM keys, no scheduled tasks, no services, no files outside your own profile.

---

## Reverting

To restore all Dropbox context menu entries:

```powershell
.\ContextMenuBlocker.ps1 -UnblockAll -NoPrompt
```

Or use option **2** in the interactive menu.

---

## Security

An  [AI security assessment ](https://grok.com/share/bGVnYWN5_e1f2cac5-5e0f-4731-bbbe-63fd72af7a7b) found **no malicious behavior** of any kind — no data exfiltration, no network connections, no unauthorized privilege escalation, no obfuscation. 

The script is fully open and readable. You're encouraged to review it yourself, or paste it into any AI assistant and ask for a security assessment.

 The script has also been shared and discussed on the **[Dropbox Community forum](https://www.dropboxforum.com/discussions/101001016/remove-dropbox-context-menu-entries-on-windows---persistent-fix/858008)**, where users can speak to its real-world effectiveness.

---

## Adapting for Other Applications

The configuration section at the top of the script is designed to be modified. To target a different UWP/MSIX application, change only the `APPLICATION PROFILE` block:

```powershell
$Script:Config = @{
    AppName            = "YourApp"
    AppPackagePattern  = "Publisher.AppName_*"
    VersionRegex       = 'Publisher\.AppName_([0-9]+(?:\.[0-9]+)*)_'
    VerbParseRegex     = 'AppName\d*(.+?)(?:Command)?\d*$'
    # ... paths and behavior options stay the same
}
```

---

## License

AGPL-3.0
