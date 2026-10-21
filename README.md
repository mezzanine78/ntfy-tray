# ntfy Tray (NtfyTray)

A small [ntfy](https://ntfy.sh) client for the **Windows 11 system tray**, written in PowerShell.
It subscribes to one or more topics on one or more ntfy servers (self-hosted with an access
token, or public), shows **native Windows toast notifications** that follow ntfy priority,
tags, click URLs and `view` action buttons, and keeps a recent-messages list in the tray.

Modelled on [simoneferrari/ntfy-desktop](https://github.com/simoneferrari/ntfy-desktop)
(MIT, C#/WPF). See [Credits](#credits-and-alternatives).

- Per-user install, no admin, no compiled code: Windows PowerShell 5.1 + WinForms + WinRT toasts.
- Access tokens are stored DPAPI-encrypted for your Windows user, never in `config.json` or the repo.
- Reconnects with backoff and resumes with `since=`, so nothing is missed or shown twice after a
  network drop, sleep/hibernate, or reboot. Missed messages are summarised in one
  "N messages while you were away" toast.

## Requirements

| | |
|---|---|
| OS | Windows 10 1809+ / Windows 11 (toasts with `scenario="urgent"` need Windows 11 22H2+, older builds show them as normal toasts) |
| PowerShell | Windows PowerShell 5.1 (built in). The tray always runs under 5.1. PowerShell 7 works for `-SelfTest` / `-Console`; if you launch the tray with pwsh 7 it uses [BurntToast](https://www.powershellgallery.com/packages/BurntToast) when installed, or plain balloon tips |
| Server | Any ntfy server. A self-hosted server with auth needs an [access token](https://docs.ntfy.sh/config/#access-tokens) that can **read** the topics |
| Network | Outbound HTTPS to your ntfy server (and to github.com for install/update) |

## Install (one line)

> **The one-liner only works while the GitHub repo is public.** `raw.githubusercontent.com`
> and the repo zip download return 404 for private repos. For a private repo use the
> [clone method](#install-from-a-clone-private-repo).

In PowerShell (no admin needed):

```powershell
irm https://raw.githubusercontent.com/mezzanine78/ntfy-tray/main/install.ps1 | iex
```

The installer:

1. Downloads the repo zip and copies the app to `%LOCALAPPDATA%\NtfyTray`.
2. Asks for the **server URL**, the **topic(s)** (comma-separated) and the **access token**
   (typed hidden; leave it blank for public topics). It checks the token against
   `https://<server>/<topic>/auth` and tells you if it was accepted.
3. Registers the toast app id, adds a Start-menu shortcut **ntfy Tray**, turns on
   **start with Windows**, and starts the app. A round icon with **n** appears in the tray (it
   may be hidden in the `^` overflow, so drag it onto the taskbar to keep it visible).

Installer options, if you need them:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/mezzanine78/ntfy-tray/main/install.ps1))) `
    -Server https://ntfy.example.com -Topics alerts,backups -NoAutostart
```

| Option | Meaning |
|---|---|
| `-Server <url>` / `-Topics a,b` | Skip the prompts |
| `-NoToken` | Server/topics need no token |
| `-Reconfigure` | Ask for server/topics/token again on an existing install |
| `-NoAutostart` | Do not start with Windows |
| `-NoStart` | Do not launch after installing |
| `-Ref <branch-or-tag>` | Install a specific branch or tag (default `main`) |
| `-Uninstall [-RemoveToken] [-RemoveAll]` | See [Uninstall](#uninstall) |

### Install from a clone (private repo)

```powershell
gh auth login                      # once per machine (GitHub CLI)
gh repo clone mezzanine78/ntfy-tray
cd ntfy-tray
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

A release zip works the same way: extract it and run `install.ps1` from the extracted folder.

## Configuration

Everything lives in `%APPDATA%\NtfyTray\`:

| File | What |
|---|---|
| `config.json` | Servers, topics, filters, autostart. Edit it from the tray menu with **Open config file**, then **Reload config** |
| `tokens\<server>.token` | Access token, DPAPI-encrypted (`ConvertFrom-SecureString`, CurrentUser). Only your Windows account on this PC can decrypt it |
| `state\<server>.cursor.json` | Resume cursor: last message time and the last 500 message ids (no message content) |
| `ntfytray.log` | Log (rotates at 1 MB). Contains connection events and errors, never tokens or message bodies |

### config.json

Short form, with one server and a list of topics:

```json
{
  "Server": "https://ntfy.example.com",
  "Topics": ["alerts", "backups"]
}
```

Full form, written by the app. It supports several servers and per-topic settings:

```json
{
  "Servers": [
    { "Name": "home", "Url": "https://ntfy.example.com", "Auth": "token" },
    { "Name": "public", "Url": "https://ntfy.sh", "Auth": "none" }
  ],
  "Topics": [
    { "Server": "home", "Name": "alerts", "DisplayName": "Server alerts", "MinPriority": 0, "Paused": false, "Enabled": true },
    { "Server": "home", "Name": "backups", "DisplayName": "", "MinPriority": 4, "Paused": false, "Enabled": true },
    { "Server": "public", "Name": "my-public-topic", "DisplayName": "", "MinPriority": 0, "Paused": false, "Enabled": true }
  ],
  "MinPriority": 1,
  "Paused": false,
  "ActiveHours": { "Enabled": false, "Start": "09:00", "End": "18:00" },
  "Autostart": true,
  "CatchUpSummary": true,
  "RecentCount": 50,
  "IdleTimeoutSec": 120
}
```

| Key | Meaning |
|---|---|
| `Servers[].Auth` | `token` (use the stored token) or `none` |
| `Topics[].MinPriority` | Toast only at or above this priority for this topic (`0` = use the global `MinPriority`) |
| `Topics[].Paused` / `Paused` | Mute toasts for one topic or for everything. The connection stays open and messages still land in Recent |
| `Topics[].Enabled` | `false` = do not subscribe at all |
| `ActiveHours` | Only toast inside this window (ranges across midnight like `22:00`-`06:00` work). **Priority 5 always breaks through** |
| `CatchUpSummary` | After a reconnect, show one summary toast for missed messages instead of one toast each |
| `IdleTimeoutSec` | Reconnect if nothing arrives (not even ntfy's keepalive, sent every 45 s by default) for this long. This catches dead connections after sleep or Wi-Fi changes |

Topic names may contain letters, digits, `-` and `_` (max 64), the same rules ntfy uses.
Any key that looks like a secret (`Token`, `Password`, ...) is dropped when the file is saved.

### Access token

- During install you are prompted for it (input hidden).
- To change it later: tray menu > **Set access token...**. This opens a small console window that
  prompts for each server, stores the token, checks it and makes the running app reconnect.
  Type `-` to delete a stored token.
- From PowerShell:
  ```powershell
  Import-Module "$env:LOCALAPPDATA\NtfyTray\NtfyTray.Core.psm1"
  Set-NtfyToken -Server https://ntfy.example.com        # prompts, input hidden
  Remove-NtfyToken -Server https://ntfy.example.com
  ```
- Tokens are sent only over `https://` (or to `localhost`). A token is never attached to a plain
  `http://` server, the same rule ntfy-desktop uses.
- Create a read-only token on the server for this client, for example
  `ntfy token add --label "NtfyTray PC1" <user>` plus `ntfy access <user> <topic> read-only`.

## Using it

| Tray | Action |
|---|---|
| Icon colour | **green** = all servers connected, **amber** = reconnecting / some connected, **red** = disconnected or token rejected, **grey** = no topics. The number on the icon is the unread count. A small pause mark shows when notifications are paused |
| Left click | Recent-messages window (double-click a row to open its link, or use **Copy text**) |
| Right click | Server status lines (hover for the last error), **Recent messages**, **Show recent messages...**, **Mark all read**, **Pause/Resume notifications**, **Reconnect all**, **Start with Windows**, **Set access token...**, **Open config file**, **Reload config**, **Open log**, **Check for updates...**, **Exit** |

Pause from the menu lasts until you resume or restart the app. For a permanent pause set `"Paused": true` in the config.

### How ntfy fields map to Windows toasts

| ntfy priority | Toast |
|---|---|
| 1 min | Silent, attribution "Min" |
| 2 low | Silent, attribution "Low" |
| 3 default | Normal toast with the default sound |
| 4 high | `reminder` scenario (stays on screen until dismissed), reminder sound, **Dismiss** button, "High" badge |
| 5 urgent | `urgent` scenario (Windows 11 22H2+ can show it through Do Not Disturb if you allow that in Settings), long duration, looping alarm sound, **Dismiss** button, "Urgent" badge, ignores active hours |

| ntfy field | Toast |
|---|---|
| `title` | Toast title (the topic name or display name when there is no title) |
| `message` | Body. Markdown messages are flattened to plain text |
| `tags` | Known emoji shortcodes (all ~1,850 gemoji aliases, for example `warning`, `rotating_light`, `white_check_mark`, `tada`, `skull`) are prefixed to the title as emoji. Other tags are shown as `#tag` at the end of the body |
| `click` | Clicking the toast opens this URL in your browser. Only `http(s)` URLs are opened; `file:`, `javascript:` and similar are ignored |
| `actions` of type `view` | Up to 3 buttons that open their URL (http(s) only) |
| `actions` of type `http` / `broadcast` / `copy` | Not shown on toasts (see [Limitations](#limitations)) |
| `attachment` | Body shows `[attachment] <name>` |

## Autostart

Autostart is on by default: the installer writes
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run\NtfyTray` pointing at `wscript.exe NtfyTray.vbs`,
which starts PowerShell hidden. Toggle it with tray menu > **Start with Windows**, or
`"Autostart": false` in the config, or install with `-NoAutostart`.

## Update

Re-run the same one-liner. It stops the running app, replaces the program files, **keeps
`config.json`, the token and the resume cursor**, and starts the new version. Add `-Reconfigure`
to change server/topics/token. Tray menu > **Check for updates...** compares your version with
`src/VERSION` on GitHub and offers to run the one-liner (public repo only). For a private repo, run
`git pull` in your clone and then `.\install.ps1` again.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\NtfyTray\uninstall.ps1"
```

This removes the app files, the Start-menu shortcut, the autostart entry and the toast registration.
It asks whether to delete the stored token too. `-RemoveToken` deletes the token without asking.
`-RemoveAll` deletes all of `%APPDATA%\NtfyTray` (config, cursor, token, log).
From the one-liner:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/mezzanine78/ntfy-tray/main/install.ps1))) -Uninstall -RemoveAll
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| No tray icon | Look in the `^` overflow. Check `%APPDATA%\NtfyTray\ntfytray.log`. Run it visibly to see errors: `powershell -ExecutionPolicy Bypass -STA -File "$env:LOCALAPPDATA\NtfyTray\NtfyTray.ps1"` |
| Icon red, status "auth failed" | Token missing, wrong or without read access. Use **Set access token...**. Check it with `-SelfTest` (below). After a 401/403 the app waits 5 minutes before retrying, or you can use **Reconnect all** |
| Icon amber for a long time | The server is unreachable or rate-limiting (HTTP 429, waits 60 s). Hover the status line for the error |
| No toasts but messages appear in Recent | Settings > System > Notifications: make sure notifications are on and **ntfy Tray** is allowed. Do Not Disturb / Focus hides normal toasts. Also check `MinPriority`, `ActiveHours`, `Paused` and per-topic `Paused` |
| Toasts show as old-style balloon tips | You launched with PowerShell 7 and BurntToast isn't installed. Use the shortcut (it runs Windows PowerShell 5.1) or `Install-Module BurntToast -Scope CurrentUser` |
| "Running scripts is disabled" | The launcher passes `-ExecutionPolicy Bypass`. For manual runs use `powershell -ExecutionPolicy Bypass -File ...` |
| One-liner fails with 404 | The repo is private. Use the [clone method](#install-from-a-clone-private-repo) |
| Token was copied to a new PC or user | DPAPI tokens only decrypt for the same Windows user on the same PC. Set the token again on the new machine |

Self-test (any PowerShell): checks the token against each topic and counts the last hour of
messages without showing their content:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\NtfyTray\NtfyTray.ps1" -SelfTest
```

Console mode prints messages as they arrive, which is handy to see exactly what the server sends:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\NtfyTray\NtfyTray.ps1" -Console
```

## How it works

```
install.ps1                 installer / updater / -Uninstall (irm | iex friendly)
src/NtfyTray.ps1            tray UI (WinForms NotifyIcon), toasts, -SetToken / -SelfTest / -Console
src/NtfyTray.Core.psm1      UI-free logic: config, DPAPI tokens, URL building, JSON stream, cursor, mapping
src/NtfyTray.vbs            hidden launcher (wscript -> powershell -WindowStyle Hidden)
src/uninstall.ps1           uninstaller (copied to the install folder)
src/emoji-tags.json         ntfy tag -> emoji map (generated from gemoji by tools/Build-EmojiMap.ps1)
src/VERSION                 app version (used by Check for updates)
tests/                      Pester unit tests + live stream tests
tools/                      syntax check, secret scan, release zip, emoji map builder
```

- **One HTTP stream per server** on `GET /<topic1>,<topic2>/json` in a background runspace, so the UI
  never blocks. The UI thread drains a queue every 500 ms.
- **Resume:** each message updates a per-server cursor (newest message time + last 500 ids).
  On every reconnect the stream opens with `since=<last time>`. A timestamp is used instead of a
  message id, as ntfy-desktop does: an id that has aged out of the server cache returns nothing,
  but an old timestamp returns whatever is still cached. ntfy's `since=<time>` is inclusive, and the
  seen-id list drops the repeat, so nothing is duplicated. Messages older than the connect time are
  backfill and go into the summary toast.
- **Reconnect:** backoff of 1, 2, 4, 8, 16, 30, then 60 s (+0-20% jitter), at least 60 s after HTTP
  429 and 5 min after 401/403. The token is re-read on every attempt, so a new token takes effect
  without a restart.
- **Toasts:** WinRT `Windows.UI.Notifications` from PowerShell 5.1, with an AppUserModelID
  registered under `HKCU\Software\Classes\AppUserModelId\mezzanine78.NtfyTray`. Clicks and `view`
  buttons use protocol activation (the browser opens the URL), so no COM activator is needed.

## Limitations

- `http` and `copy` action buttons are not rendered on toasts. Firing HTTP requests from a toast needs
  a COM activator or a protocol handler. `broadcast` is Android-only.
- No publishing or compose window: this is a receive-only client.
- Recent messages are kept in memory only (`RecentCount`, default 50), not in an encrypted history
  database like ntfy-desktop's.
- Username/password auth isn't supported, only tokens or anonymous access.
- No WebSocket transport: the client uses the JSON HTTP stream, which works through more proxies.

## Credits and alternatives

- **[ntfy-desktop](https://github.com/simoneferrari/ntfy-desktop)** by Simone Ferrari and
  contributors (MIT) is the design reference. NtfyTray mirrors its connection model (timestamp cursor,
  backfill detection, catch-up summary, backoff schedule), its notification mapping (priority
  scenarios and sounds, emoji tags, safe click URLs), DPAPI token storage, AUMID registration, pause
  and active hours, and its tray status colours. No source code was copied. See
  [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
  **If you want a full GUI client** with message history, multiple-server management, attachments,
  rule packs and auto-update, use ntfy-desktop itself. It is the most complete native Windows client
  (still v0.x pre-release).
- Other options: the official ntfy **PWA** installed from Edge or Chrome (needs Web Push configured on a
  self-hosted server), or `ntfy subscribe` from the [ntfy CLI](https://docs.ntfy.sh/subscribe/cli/)
  combined with BurntToast.
- Emoji shortcodes come from [gemoji](https://github.com/github/gemoji) (MIT), the same data ntfy uses.

## Development

```powershell
pwsh ./tools/Test-Syntax.ps1                       # parser + PSScriptAnalyzer (5.1 / 7 syntax compatibility)
Invoke-Pester ./tests/NtfyTray.Core.Tests.ps1      # offline unit tests
pwsh ./tests/Invoke-LiveTests.ps1 -NtfySh          # end-to-end on a random throwaway ntfy.sh topic
pwsh ./tests/Invoke-LiveTests.ps1 -LocalUrl http://127.0.0.1:8080   # against a local `ntfy serve`
#   (set visitor-request-limit-exempt-hosts: "127.0.0.1" in its server.yml, or ntfy's per-visitor
#    rate limit returns HTTP 429 during the test and the client correctly backs off for 60+ s)
pwsh ./tools/Test-Secrets.ps1                      # secret scan (folder + staged files)
pwsh ./tools/Build-Release.ps1                     # dist/ntfy-tray-v<version>.zip
```

MIT licensed, see [LICENSE](LICENSE).
