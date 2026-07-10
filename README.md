# Code-Notify

> **Official downloads**: https://github.com/xuyangy/code-notify/releases
>
> **Install**: `curl -sSL https://raw.githubusercontent.com/xuyangy/code-notify/main/scripts/install.sh | bash`

Desktop notifications for AI coding tools - get alerts when tasks complete or input is needed.

## Latest: Usage Limit Reset Alerts

Code-Notify can now watch Codex and Claude usage limits and tell you when tokens are back.

- **Daily reset**: `Codex token daily limit reset`
- **Weekly reset**: `Codex token weekly limit reset`
- **Low-usage warnings**: 20% and 10% remaining
- **Delivery options**: desktop notification, voice, sound, Slack, Discord, or ntfy phone push

Voice samples: [Daily reset](https://cdn.jsdelivr.net/gh/xuyangy/code-notify@main/assets/audio/codex-token-daily-limit-reset.m4a) · [Weekly reset](https://cdn.jsdelivr.net/gh/xuyangy/code-notify@main/assets/audio/codex-token-weekly-limit-reset.m4a)

```bash
cn usage setup --watch
cn usage status
```

`cn usage setup --watch` enables usage alerts, turns on distinct reset voice/sound, and starts a background watcher.

![Usage limit reset alerts terminal demo](assets/usage-alerts-terminal.svg)

<p>
  <img src="assets/multi-tools-support.png" width="48%" alt="Multi-tool support"/>
  <img src="assets/multi-tools-support-02.png" width="48%" alt="All tools enabled"/>
</p>

[![Version](https://img.shields.io/badge/version-1.10.0-blue.svg)](https://github.com/xuyangy/code-notify/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-supported-green.svg)](https://www.apple.com/macos)
[![Linux](https://img.shields.io/badge/Linux-supported-green.svg)](https://www.linux.org/)
[![Windows](https://img.shields.io/badge/Windows-supported-green.svg)](https://www.microsoft.com/windows)

---

## What's New in v1.10.0

- **One-command usage setup**: `cn usage setup --watch` configures Codex/Claude usage alerts and starts the background watcher
- **Background usage watcher**: macOS/Linux users can start, stop, restart, and inspect usage watching with `cn usage watch ...`
- **Usage alert docs**: README now shows the terminal setup flow and Slack/Discord reset alert routing

---

## Features

- **Multi-tool support** - Claude Code, OpenAI Codex, Google Gemini CLI, Google Antigravity CLI (`agy`)
- **Works everywhere** - Terminal, VSCode, Cursor, or any editor
- **Cross-platform** - macOS, Linux, Windows
- **Native notifications** - Uses system notification APIs
- **macOS click-through control** - Choose which app notification clicks activate
- **tmux click-to-focus** - Clicking a notification jumps to the exact tmux window/pane the tool runs in (macOS; uses [alerter](https://github.com/vjeantet/alerter) for persistent alerts when installed)
- **tmux window badges** - The originating tmux window's name gets the event icon prepended ("🟢 zsh"), so pending work is visible in the status line. For Claude and Codex (hooks.json installs) the badge marks a window as waiting for you and stays until you actually give it more work (it clears on your next prompt in that window), so a glance at the output doesn't wipe it. For Antigravity and legacy Codex `notify =` setups — which have no prompt signal — it clears the moment you switch to the window (manually, by clicking the notification, or via terminal-notifier `-focusLast`). Renaming a badged window yourself keeps your name. By default waiting-type events (idle reminder, permission request) skip the window you are currently looking at — only completion/error badge it; `cn badge-visible on` (or `CODE_NOTIFY_TMUX_BADGE_VISIBLE=true` for a single session) makes every event badge the focused window too. Disable badges entirely with `CODE_NOTIFY_TMUX_BADGE=false` or `touch ~/.claude/notifications/tmux-badge-disabled`
- **tmux running indicator** - While Claude, Codex (hooks.json installs), or Antigravity works on a prompt, its window name carries 🌕 so you can see which windows have an agent busy. Prefer an animated 🌑🌒🌓🌔🌕🌖🌗🌘 spinner in the status line instead? `cn spinner on` renders it via tmux's own status refresh. A lightweight 5-second check clears either indicator and a pending badge when the agent process exits without a lifecycle hook; set `CODE_NOTIFY_TMUX_AGENT_EXIT_POLL_SECONDS=0` to disable that check. While a permission request or MCP elicitation is waiting, a 2-second check of the pane's rendered content brings the indicator back the moment you answer — Claude Code fires no hook on approval itself, only when the approved tool finishes, so without this a long approved command would show no indicator until it completed (merely glancing at the waiting window doesn't trip it); tune with `CODE_NOTIFY_TMUX_RESUME_POLL_SECONDS` (0 disables) and `CODE_NOTIFY_TMUX_RESUME_POLL_TTL` (how long an unanswered request keeps the check alive, default 15 minutes). The indicator still self-expires after 4 hours (`CODE_NOTIFY_TMUX_RUNNING_TTL`) as a safety net for runs that end without a hook — on tmux older than 3.2 the expiry instead lands with the next notification or prompt on that server; disable entirely with `CODE_NOTIFY_TMUX_RUNNING=false`, or change the static icon with `CODE_NOTIFY_TMUX_RUNNING_ICON`
- **Sound notifications** - Play custom sounds on task completion
- **Voice announcements** - Hear when tasks complete (macOS, Windows)
- **ElevenLabs voices** - Optional high-quality cloud TTS for voice announcements (macOS)
- **Slack/Discord/ntfy delivery** - Mirror notifications to webhooks or your phone
- **Codex hook ownership** - Handles Codex completion and approval/edit requests through Codex hooks while disabling duplicate Codex TUI toasts
- **Usage alerts** - Opt-in Codex/Claude 20%, 10%, and reset notifications
- **Rotating tool-specific messages** - "Claude is idle", "Codex wrapped up", and other short variants are chosen randomly per event
- **Project-specific settings** - Different configs per project
- **Quick aliases** - `cn` and `cnp` for fast access

## Installation

### For Humans

**macOS / Linux / WSL**

```bash
curl -sSL https://raw.githubusercontent.com/xuyangy/code-notify/main/scripts/install.sh | bash
cn on
```

**Windows**

```powershell
irm https://raw.githubusercontent.com/xuyangy/code-notify/main/scripts/install-windows.ps1 | iex
```

**Update an existing install**

```bash
cn update
code-notify version
```

**Install a specific version (advanced)**

By default the installer pulls the latest `main`. Set `CODE_NOTIFY_REF` to install a
specific branch, tag, or commit SHA instead — useful for pinning a known-good
version or testing a branch:

```bash
# pin to a release tag
curl -sSL https://raw.githubusercontent.com/xuyangy/code-notify/main/scripts/install.sh | CODE_NOTIFY_REF=v1.10.0 bash

# or a branch / commit SHA
CODE_NOTIFY_REF=my-branch bash scripts/install.sh
```

Note: `CODE_NOTIFY_REF` selects the code that gets installed; the `install.sh` you pipe
to `bash` is always fetched from `main`. The ref is ignored when installing from a local
checkout (it copies your working tree).

If you were using the older `claude-notify` hook layout, supported upgrades now repair those Claude hooks automatically. On Windows, that repair also covers older `notify.ps1` hook layouts and alternate Claude settings locations such as `%USERPROFILE%\.config\.claude\settings.json`. Existing unrelated Claude hooks are preserved during enable/disable operations.

### For AI Coding Agents

Paste this to your AI coding agent (Claude Code, Codex, Cursor, Gemini CLI, etc.):

```
Install code-notify with the install script.

curl -sSL https://raw.githubusercontent.com/xuyangy/code-notify/main/scripts/install.sh | bash
cn on all
cn test
cn status
```

Expected result:

- `cn test` shows a desktop notification.
- `cn status` shows enabled tools.

See [docs/installation.md](docs/installation.md) for more details.

## Usage

![cn help output](assets/cn-help.png)

| Command              | Description                                  |
| -------------------- | -------------------------------------------- |
| `cn on`              | Enable notifications for all detected tools  |
| `cn on all`          | Explicit alias for enabling all detected tools |
| `cn on claude`       | Enable for Claude Code only                  |
| `cn on codex`        | Enable Codex hooks and suppress duplicate Codex TUI toasts |
| `cn on gemini`       | Enable for Gemini CLI only                   |
| `cn on antigravity`  | Enable for Antigravity CLI (`agy`); `cn on agy` also works |
| `cn off`             | Disable notifications                        |
| `cn off all`         | Explicit alias for disabling all tools       |
| `cn test`            | Send test notification                       |
| `cn status`          | Show current status                          |
| `cn update`          | Update code-notify                           |
| `cn update check`    | Check the latest release and show the update command |
| `cn click-through`   | Show current macOS click-through mappings    |
| `cn click-through add <app>` | Add a macOS click-through mapping    |
| `cn alerts`          | Configure which events trigger notifications |
| `cn alerts persist`  | Keep selected alerts visible until closed    |
| `cn channels`        | Configure Slack/Discord/ntfy delivery        |
| `cn snooze <time>`   | Pause all notifications (30m, 2h, off)       |
| `cn usage`           | Configure Codex/Claude usage alerts          |
| `cn spinner on`      | Use the animated tmux running indicator      |
| `cn spinner off`     | Use the static tmux running indicator        |
| `cn spinner status`  | Show the tmux spinner setting                |
| `cn badge-visible on` | Badge the focused tmux window on every event |
| `cn badge-visible off` | Skip the focused window for waiting events (default) |
| `cn sound on`        | Enable sound notifications                   |
| `cn sound set <path>`| Use custom sound file                        |
| `cn voice on`        | Enable voice (macOS, Windows)                |
| `cn voice on claude` | Enable voice for Claude only                 |
| `cn voice engine elevenlabs` | Use ElevenLabs cloud voice (macOS)   |
| `cn voice elevenlabs key <key>` | Store your ElevenLabs API key     |
| `cnp on`             | Enable for current project only              |

When enabling project notifications with `cnp on`, Code-Notify warns if Claude project trust does not appear to be accepted yet.
Project-scoped Claude hooks override the global mute file, so `cn off` will not suppress a project where `cnp on` is enabled.
`all` is also accepted as an explicit alias for global commands such as `cn on all`, `cn off all`, and `cn status all`.

### tmux Running Spinner

By default, an active Claude or Codex agent is marked with a static 🌕 icon in
its tmux window name. To show an animated 🌑🌒🌓🌔🌕🌖🌗🌘 indicator in tmux's
status line instead:

```bash
cn spinner on
cn spinner status
cn spinner off
```

`cn spinner on` saves the preference; the spinner is armed when the next agent
run starts. Run `cn spinner off` from inside the affected tmux server to remove
a live status-line spinner immediately. Agents that are still running fall back
to the static 🌕 window-name icon. The disarm path leaves a status format or
refresh interval that you changed while the spinner was active untouched.

Set `CODE_NOTIFY_TMUX_SPINNER=true` or `CODE_NOTIFY_TMUX_SPINNER=false` to
override the saved preference for a single process or session.

## How It Works

Code-Notify uses the hook systems built into AI coding tools:

- **Claude Code**: `~/.claude/settings.json`
- **Codex**: `~/.codex/hooks.json`
- **Gemini CLI**: `~/.gemini/settings.json`
- **Antigravity CLI (`agy`)**: imported plugin at `~/.claude/notifications/agy-plugin/` (registered with `agy plugin install`)

For Codex, Code-Notify configures `~/.codex/hooks.json` with Codex lifecycle hooks and disables Codex TUI notifications in `~/.codex/config.toml` to avoid duplicate toasts. The `Stop` hook sends task-complete notifications. When `permission_prompt` is enabled, Code-Notify also adds a `PermissionRequest` hook for approval/edit requests.

For Antigravity CLI, Code-Notify builds a small plugin and registers it with `agy plugin install`. Antigravity hooks receive their payload on stdin and pass no arguments, so each event runs a tiny wrapper that pipes the payload into the notifier. The mapping reflects what `agy` actually executes today (tested against `agy` 1.0.11):

- **Input needed** — a `PreToolUse` hook (scoped to `run_command`) fires while `agy` waits for you to approve a command. Registered only when the `permission_prompt` alert type is enabled.
- **Task complete** — `agy` has no working `Stop`/lifecycle hook yet, so completion is inferred by debouncing `PostToolUse`: once tool activity has been quiet for a few seconds (`CODE_NOTIFY_AGY_DEBOUNCE_SECONDS`, default 8), a single "task complete" notification fires. A native `Stop` hook is also installed and will take over automatically if a future `agy` build runs it.
- **Errors** — a failing `PostToolUse` (string or structured error) fires an immediate failure alert and cancels any pending "task complete" for that step.

Disable everything with `cn off antigravity`, which runs `agy plugin uninstall code-notify`.

For Claude Code, it adds hooks like:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "notify.sh stop claude" }]
      }
    ],
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [
          { "type": "command", "command": "notify.sh notification claude" }
        ]
      }
    ],
    "SubagentStop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "notify.sh SubagentStop claude" }
        ]
      }
    ]
  }
}
```

For Codex, it manages hooks like:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [{ "type": "command", "command": "notify.sh stop codex" }]
      }
    ],
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "notify.sh notification codex" }
        ]
      }
    ]
  }
}
```

And while Codex is enabled, Code-Notify owns notification delivery by writing this managed override:

```toml
[tui]
# Code-Notify: Codex notifications are handled by hooks
notifications = false
```

### Alert Types

<img src="assets/cn-status-v1.4.0.png" width="60%" alt="cn status showing alert types"/>

By default, Claude/Gemini input alerts use `idle_prompt`, while Codex always uses its `Stop` hook for task completion. You can customize additional alert types:

```bash
cn alerts                          # Show current config
cn alerts add permission_prompt    # Also notify on tool permission requests
cn alerts add ask_user             # Notify immediately when Claude asks a question
cn alerts add SubagentStop         # Also notify when Claude subagents finish
cn alerts remove permission_prompt # Remove permission notifications
cn alerts reset                    # Back to default (idle_prompt only)
```

| Type                 | Description                                    |
| -------------------- | ---------------------------------------------- |
| `idle_prompt`        | AI is waiting for your input (default)         |
| `permission_prompt`  | AI needs tool permission (Y/n)                 |
| `auth_success`       | Authentication success                         |
| `elicitation_dialog` | MCP tool input needed                          |
| `ask_user`           | Claude asks a question via AskUserQuestion     |
| `SubagentStart`      | Claude subagent started                        |
| `SubagentStop`       | Claude subagent completed                      |
| `TeammateIdle`       | Claude teammate is waiting for input           |
| `TaskCreated`        | Claude agent-team task was created             |
| `TaskCompleted`      | Claude agent-team task completed               |

Alert-type matching applies to Claude Code notification hooks, Codex `PermissionRequest` hooks, Gemini CLI notification hooks, and the Antigravity CLI `PreToolUse` hook. For Antigravity, `permission_prompt` controls whether the approval (`PreToolUse`) alert is installed. `ask_user` is a Claude-only `PreToolUse` hook for `AskUserQuestion`; it is applied immediately when Claude notifications are already enabled. Claude Code agent/team events are separate hook events and are opt-in via `cn alerts add SubagentStop`, `cn alerts add TeammateIdle`, or `cn alerts add TaskCompleted`. After changing alert types, run `cn on` or `cn on codex` (or `cn on antigravity`) again to rewrite the managed hooks.

Agent-team and subagent workflows can be noisy if `permission_prompt` is enabled. If you only want idle pings for Claude/Gemini and completion alerts for Codex, run `cn alerts remove permission_prompt && cn on`. Codex does not expose an `idle_prompt` hook through Code-Notify; `permission_prompt` controls Codex approval/edit alerts through `PermissionRequest`.

For each delivered event, Code-Notify randomly chooses from a small set of short messages for that event. For example, an `idle_prompt` may say `Claude is idle`, `Claude is waiting`, `Claude is ready for you`, or `Claude paused for input`.

### Persistent Notifications

By default, desktop notifications auto-hide after a few seconds. You can mark specific alert types as persistent so they stay visible until you close them, or until a timeout you choose (default 12 hours):

```bash
cn alerts persist add permission_prompt  # Keep permission requests on screen
cn alerts persist add stop               # Keep task-complete alerts on screen
cn alerts persist timeout 12h            # Hide after 12 hours (default)
cn alerts persist timeout 0              # Stay until manually closed
cn alerts persist                        # Show current config
cn alerts persist reset                  # Back to normal banners
```

- **macOS**: requires [alerter](https://github.com/vjeantet/alerter) (`brew install alerter`); without it, persistent types fall back to normal banners. Clicking the alert still focuses your terminal (and the originating tmux window/pane when applicable).
- **Linux**: persistent alerts are sent with critical urgency, which GNOME/KDE keep on screen until dismissed.
- **Windows**: persistent alerts use a reminder toast with a Dismiss button.

Persistence only changes how long a notification stays visible. Which events notify at all is still controlled by `cn alerts add/remove`, and `stop` (task complete) can be made persistent even though it is not an alert-type filter.

### Slack, Discord, And ntfy (Phone Push)

Code-Notify can also send the same notification to Slack, Discord, or [ntfy](https://ntfy.sh) through webhooks. Desktop notifications still work normally; remote delivery is an extra channel. ntfy delivers push notifications to your phone via the ntfy app — subscribe to your topic there, and pick a hard-to-guess topic name since topics are open by default.

```bash
cn channels add slack https://hooks.slack.com/services/...
cn channels add discord https://discord.com/api/webhooks/...
cn channels add ntfy https://ntfy.sh/my-private-topic --name phone
cn channels status
cn channels test all
```

Webhook URLs are stored locally in `~/.config/code-notify/channels.json` and are redacted in `cn status`. Self-hosted ntfy servers work too (any `https://<server>/<topic>` URL).

### Snooze

Pause every notification — including approval prompts — for a fixed time, then resume automatically. No daemon involved; expiry is checked when the next event fires.

```bash
cn snooze 30m     # also accepts 2h, 90s, or bare minutes
cn snooze status
cn snooze off
```

### ElevenLabs Voices

By default, voice announcements use the built-in macOS voice (`say`). You can switch to [ElevenLabs](https://elevenlabs.io) for higher-quality cloud voices.

```bash
cn voice on                                  # Enable voice first
cn voice engine elevenlabs                   # Switch TTS engine
cn voice elevenlabs key <your-api-key>       # Store your API key
cn voice elevenlabs list                     # List voices (with category + plan)
cn voice elevenlabs voice <voice-id>         # Pick a voice (default: Rachel)
cn voice elevenlabs model <model-id>         # Default: eleven_flash_v2_5
cn voice elevenlabs test                     # Speak a test message
cn voice engine system                       # Switch back to the built-in voice
```

Notes:

- ElevenLabs voice applies on macOS. If a call fails (no key, network error, or quota exhausted), Code-Notify automatically falls back to the built-in `say` voice so you still hear the announcement. `cn voice elevenlabs test` reports the specific API error when it fails.
- `cn voice elevenlabs list` shows each voice's category and plan. Voices marked `paid only` (ElevenLabs `professional`/`library` voices) require a paid ElevenLabs plan; voices marked `free ok` (e.g. `premade`) work on the free tier.
- Synthesized audio is cached in `~/.cache/code-notify/tts/`, so repeated selected phrases do not make repeat API calls.
- Your API key is stored locally in `~/.config/code-notify/tts.json` (permissions `600`) and is redacted in `cn voice status`.
- `eleven_flash_v2_5` is the default model — it is the fastest and cheapest, which suits short notification phrases. Use `eleven_multilingual_v2` for higher quality.

#### Free-tier voices and preview links

The exact list comes from your ElevenLabs account at runtime, but these are the standard free-tier-safe `premade` voices. Open any preview URL in your browser to hear the sample voice before setting it in Code-Notify.

| Voice | Voice ID | Preview |
| --- | --- | --- |
| Roger | `CwhRBWXzGAHq8TQ4Fs17` | [hear](https://api.us.elevenlabs.io/v1/voices/CwhRBWXzGAHq8TQ4Fs17/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiI1OGVlM2ZmNS1mNmYyLTQ2MjgtOTNiOC1lMzhlYjMxODA2YjAubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Sarah | `EXAVITQu4vr4xnSDxMaL` | [hear](https://api.us.elevenlabs.io/v1/voices/EXAVITQu4vr4xnSDxMaL/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiIwMWEzZTMzYy02ZTk5LTRlZTctODU0My1mZjIyMTZhMzIxODYubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Laura | `FGY2WhTYpPnrIDTdsKH5` | [hear](https://api.us.elevenlabs.io/v1/voices/FGY2WhTYpPnrIDTdsKH5/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiI2NzM0MTc1OS1hZDA4LTQxYTUtYmU2ZS1kZTEyZmU0NDg2MTgubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Charlie | `IKne3meq5aSn9XLyUdCD` | [hear](https://api.us.elevenlabs.io/v1/voices/IKne3meq5aSn9XLyUdCD/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiIxMDJkZTZmMi0yMmVkLTQzZTAtYTFmMS0xMTFmYTc1YzU0ODEubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| George | `JBFqnCBsd6RMkjVDRZzb` | [hear](https://api.us.elevenlabs.io/v1/voices/JBFqnCBsd6RMkjVDRZzb/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiJlNjIwNmQxYS0wNzIxLTQ3ODctYWFmYi0wNmE2ZTcwNWNhYzUubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Callum | `N2lVS1w4EtoT3dr4eOWO` | [hear](https://api.us.elevenlabs.io/v1/voices/N2lVS1w4EtoT3dr4eOWO/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiJhYzgzM2JkOC1mZmRhLTQ5MzgtOWViYy1iMGY5OWNhMjU0ODEubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| River | `SAz9YHcvj6GT2YYXdXww` | [hear](https://api.us.elevenlabs.io/v1/voices/SAz9YHcvj6GT2YYXdXww/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiJlNmM5NWYwYi0yMjI3LTQ5MWEtYjNkNy0yMjQ5MjQwZGVjYjcubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Harry | `SOYHLrjzK2X1ezoPC6cr` | [hear](https://api.us.elevenlabs.io/v1/voices/SOYHLrjzK2X1ezoPC6cr/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiI4NmQxNzhmNi1mNGI2LTRlMGUtODViZS0zZGUxOWY0OTA3OTQubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Liam | `TX3LPaxmHKxFdv7VOQHJ` | [hear](https://api.us.elevenlabs.io/v1/voices/TX3LPaxmHKxFdv7VOQHJ/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiI2MzE0ODA3Ni02MzYzLTQyZGItYWVhOC0zMTQyNDMwOGI5MmMubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Alice | `Xb7hH8MSUJpSbSDYk0k2` | [hear](https://api.us.elevenlabs.io/v1/voices/Xb7hH8MSUJpSbSDYk0k2/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiJkMTBmNzUzNC0xMWY2LTQxZmUtYTAxMi0yZGUxZTQ4MmQzMzYubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Matilda | `XrExE9yKIg1WjnnlVkGX` | [hear](https://api.us.elevenlabs.io/v1/voices/XrExE9yKIg1WjnnlVkGX/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiJiOTMwZTE4ZC02YjRkLTQ2NmUtYmFiMi0wYWU5N2M2ZDg1MzUubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Will | `bIHbv24MWmeRgasZH58o` | [hear](https://api.us.elevenlabs.io/v1/voices/bIHbv24MWmeRgasZH58o/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiI4Y2FmOGYzZC1hZDI5LTQ5ODAtYWY0MS01M2YyMGM3MmQ3YTQubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Jessica | `cgSgspJ2msm6clMCkdW9` | [hear](https://api.us.elevenlabs.io/v1/voices/cgSgspJ2msm6clMCkdW9/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiI1NmE5N2JmOC1iNjliLTQ0OGYtODQ2Yy1jM2ExMTY4M2Q0NWEubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Eric | `cjVigY5qzO86Huf0OWal` | [hear](https://api.us.elevenlabs.io/v1/voices/cjVigY5qzO86Huf0OWal/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiJkMDk4ZmRhMC02NDU2LTQwMzAtYjNkOC02M2FhMDQ4YzkwNzAubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Bella | `hpp4J3VqNfWAUOO0d1Us` | [hear](https://api.us.elevenlabs.io/v1/voices/hpp4J3VqNfWAUOO0d1Us/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiJkYWIwZjViYS0zYWE0LTQ4YTgtOWZhZC1mMTM4ZmVhMTEyNmQubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Chris | `iP95p4xoKVk53GoZ742B` | [hear](https://api.us.elevenlabs.io/v1/voices/iP95p4xoKVk53GoZ742B/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiIzZjRiZGU3Mi1jYzQ4LTQwZGQtODI5Zi01N2ZiZjkwNmY0ZDcubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Brian | `nPczCjzI2devNBz1zQrb` | [hear](https://api.us.elevenlabs.io/v1/voices/nPczCjzI2devNBz1zQrb/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiIyZGQzZTcyYy00ZmQzLTQyZjEtOTNlYS1hYmM1ZDRlNWFhMWQubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Daniel | `onwK4e9ZLuTAKqWW03F9` | [hear](https://api.us.elevenlabs.io/v1/voices/onwK4e9ZLuTAKqWW03F9/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiI3ZWVlMDIzNi0xYTcyLTRiODYtYjMwMy01ZGNhZGMwMDdiYTkubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Lily | `pFZP5JQG7iQjIQuC4Bku` | [hear](https://api.us.elevenlabs.io/v1/voices/pFZP5JQG7iQjIQuC4Bku/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiI4OWI2OGIzNS1iM2RkLTQzNDgtYTg0YS1hM2MxM2EzYzJiMzAubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Adam | `pNInz6obpgDQGcFmaJgB` | [hear](https://api.us.elevenlabs.io/v1/voices/pNInz6obpgDQGcFmaJgB/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiJkNjkwNWQ3YS1kZDI2LTQxODctYmZmZi0xYmQzYTVlYTdjYWMubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |
| Bill | `pqHfZKP75CvOlQylNhV4` | [hear](https://api.us.elevenlabs.io/v1/voices/pqHfZKP75CvOlQylNhV4/previews/audio?payload=eyJ2b2ljZV9zb3VyY2UiOiJwcmVtYWRlIiwiZmlsZW5hbWUiOiJkNzgyYjNmZi04NGJhLTQwMjktODQ4Yy1hY2YwMTI4NTUyNGQubXAzIiwidGltZXN0YW1wIjoxNzgxOTAyODAwMDAwMDAwfQ%3D%3D) |

Some preview URLs are direct public MP3 links; others are signed ElevenLabs preview URLs and may expire. If one stops working, run `cn voice elevenlabs list` again and use the current preview from ElevenLabs' website.

### Usage Alerts

Usage alerts are opt-in for Codex and Claude. Fast setup:

```bash
cn usage setup --watch
cn usage status
```

That enables usage alerts, sets the default 20% and 10% warning thresholds, enables distinct reset voice/sound, and starts a background watcher.

Manual setup:

```bash
cn usage on                         # Enable usage alerts
cn usage thresholds set 20,10       # Warn at 20% and 10% remaining
cn usage reset-alerts voice on      # Speak reset alerts
cn usage reset-alerts sound default # Use the reset sound
cn usage check                      # Run one check now
cn usage watch start --interval 300 # Keep watching in the background
```

Code-Notify checks the daily (5h) and weekly (7d) usage windows. It sends a warning when remaining usage crosses 20% or 10%, and sends a reset notification when a window returns to 100%.

`cn usage check` runs once and exits. `cn usage watch start` keeps watching in the background on macOS/Linux. Use `cn usage watch stop` to stop it.

Terminal demo:

```bash
cn usage setup --watch
cn usage status
```

Reset alerts are intentionally separate from normal task-complete alerts. By default they use a different title, voice message, and reset sound so it is clear that tokens have refilled. The voice message identifies the window, for example `Codex token daily limit reset` or `Codex token weekly limit reset`. You can disable or customize that behavior:

```bash
cn usage reset-alerts off
cn usage reset-alerts voice off
cn usage reset-alerts sound set ~/sounds/tokens-reset.wav
```

Send reset alerts to Slack or Discord too:

```bash
cn channels add slack https://hooks.slack.com/services/...
cn channels add discord https://discord.com/api/webhooks/...
cn channels test all
```

Codex usage checks read `~/.codex/auth.json`. Claude usage checks read `~/.claude/.credentials.json`. Code-Notify does not launch provider CLIs or start login flows. Background watching starts only when you run `cn usage setup --watch` or `cn usage watch start`.

## Troubleshooting

**Command not found?**

```bash
exec $SHELL   # Reload shell
```

**No notifications?**

```bash
cn status     # Check if enabled
cn test       # Test notification
brew install terminal-notifier  # Better notifications (macOS)
```

**Notification click opens the wrong macOS app?**

```bash
cn click-through add PhpStorm
cn test
```

For headless, daemon, or background sessions (e.g. Claude Code's background runner) there is no terminal to detect, so clicks fall back to Apple Terminal. Force the target app by exporting its bundle ID — for example in `~/.zshenv` so the session inherits it:

```bash
export CODE_NOTIFY_CLICK_BUNDLE_ID=com.googlecode.iterm2   # overrides all detection
```

**Updating?**

```bash
cn update     # Update to the latest version (uses your install method)
```

**Too many `last_notification_*` files in `~/.claude/notifications`?**

Generated rate-limit state files are stored under `~/.claude/notifications/state/` instead of cluttering the root notifications folder.

## Project Structure

```
code-notify/
├── bin/           # Main executable
├── lib/           # Library code
├── scripts/       # Install scripts
├── docs/          # Documentation
└── assets/        # Images
```

## Links

- [Installation Guide](docs/installation.md)
- [Hook Configuration](docs/HOOKS_GUIDE.md)
- [Contributing](docs/CONTRIBUTING.md)
- [GitHub Issues](https://github.com/xuyangy/code-notify/issues)

## License

MIT License - see [LICENSE](LICENSE)
