# Code-Notify

> **Official downloads**: https://github.com/mylee04/code-notify/releases
>
> **Homebrew**: `brew install mylee04/tools/code-notify`
>
> **npm**: `npm install -g code-notify`

Desktop notifications for AI coding tools - get alerts when tasks complete or input is needed.

## Latest: Usage Limit Reset Alerts

Code-Notify can now watch Codex and Claude usage limits and tell you when tokens are back.

- **Daily reset**: `Codex token daily limit reset`
- **Weekly reset**: `Codex token weekly limit reset`
- **Low-usage warnings**: 20% and 10% remaining
- **Delivery options**: desktop notification, voice, sound, Slack, or Discord

Voice samples:

**Codex daily limit reset**

<video src="https://github.com/user-attachments/assets/a7e339d5-4c57-46d3-97da-cea0bf8df593" controls></video>

**Codex weekly limit reset**

<video src="https://github.com/user-attachments/assets/4455612b-c714-4457-8bf9-c37787e8f8c8" controls></video>

If GitHub does not render the inline player in your browser, open the fallback audio files: [daily](https://github.com/mylee04/code-notify/raw/main/assets/audio/codex-token-daily-limit-reset.m4a), [weekly](https://github.com/mylee04/code-notify/raw/main/assets/audio/codex-token-weekly-limit-reset.m4a).

```bash
cn usage on
cn usage reset-alerts voice on
cn usage reset-alerts sound default
```

<p>
  <img src="assets/multi-tools-support.png" width="48%" alt="Multi-tool support"/>
  <img src="assets/multi-tools-support-02.png" width="48%" alt="All tools enabled"/>
</p>

[![Version](https://img.shields.io/badge/version-1.9.0-blue.svg)](https://github.com/mylee04/code-notify/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-supported-green.svg)](https://www.apple.com/macos)
[![Linux](https://img.shields.io/badge/Linux-supported-green.svg)](https://www.linux.org/)
[![Windows](https://img.shields.io/badge/Windows-supported-green.svg)](https://www.microsoft.com/windows)

---

## What's New in v1.9.0

- **Slack and Discord delivery**: `cn channels` can mirror Code-Notify alerts to incoming webhooks
- **Codex and Claude usage alerts**: `cn usage` can warn at 20%/10% and announce daily (5h) or weekly (7d) token resets
- **Distinct reset announcements**: token reset alerts use separate voice/sound controls and include README voice samples

---

## Features

- **Multi-tool support** - Claude Code, OpenAI Codex, Google Gemini CLI
- **Works everywhere** - Terminal, VSCode, Cursor, or any editor
- **Cross-platform** - macOS, Linux, Windows
- **Native notifications** - Uses system notification APIs
- **macOS click-through control** - Choose which app notification clicks activate
- **Sound notifications** - Play custom sounds on task completion
- **Voice announcements** - Hear when tasks complete (macOS, Windows)
- **Slack/Discord delivery** - Mirror notifications to incoming webhooks
- **Usage alerts** - Opt-in Codex/Claude 20%, 10%, and reset notifications
- **Tool-specific messages** - "Claude completed the task", "Codex completed the task"
- **Project-specific settings** - Different configs per project
- **Quick aliases** - `cn` and `cnp` for fast access

## Installation

### For Humans

**macOS (Homebrew)**

```bash
brew tap mylee04/tools
brew install code-notify
cn on
```

**macOS (Homebrew, Already Installed)**

```bash
cn update
code-notify version
```

If you were using the older `claude-notify` hook layout, supported upgrades now repair those Claude hooks automatically. On Windows, that repair also covers older `notify.ps1` hook layouts and alternate Claude settings locations such as `%USERPROFILE%\.config\.claude\settings.json`. Existing unrelated Claude hooks are preserved during enable/disable operations.

**Linux / WSL**

```bash
curl -sSL https://raw.githubusercontent.com/mylee04/code-notify/main/scripts/install.sh | bash
```

**npm (macOS / Linux / Windows)**

```bash
npm install -g code-notify
cn on
```

**Windows**

```powershell
irm https://raw.githubusercontent.com/mylee04/code-notify/main/scripts/install-windows.ps1 | iex
```

### For LLM Agents

Paste this to your AI agent (Claude Code, Cursor, etc.):

```
Install code-notify by following:
https://raw.githubusercontent.com/mylee04/code-notify/main/docs/installation.md
```

Or fetch directly:

```bash
curl -s https://raw.githubusercontent.com/mylee04/code-notify/main/docs/installation.md
```

## Usage

![cn help output](assets/cn-help.png)

| Command              | Description                                  |
| -------------------- | -------------------------------------------- |
| `cn on`              | Enable notifications for all detected tools  |
| `cn on all`          | Explicit alias for enabling all detected tools |
| `cn on claude`       | Enable for Claude Code only                  |
| `cn on codex`        | Enable for Codex only                        |
| `cn on gemini`       | Enable for Gemini CLI only                   |
| `cn off`             | Disable notifications                        |
| `cn off all`         | Explicit alias for disabling all tools       |
| `cn test`            | Send test notification                       |
| `cn status`          | Show current status                          |
| `cn update`          | Update code-notify                           |
| `cn update check`    | Check the latest release and show the update command |
| `cn click-through`   | Show current macOS click-through mappings    |
| `cn click-through add <app>` | Add a macOS click-through mapping    |
| `cn alerts`          | Configure which events trigger notifications |
| `cn channels`        | Configure Slack/Discord delivery channels    |
| `cn usage`           | Configure Codex/Claude usage alerts          |
| `cn sound on`        | Enable sound notifications                   |
| `cn sound set <path>`| Use custom sound file                        |
| `cn voice on`        | Enable voice (macOS, Windows)                |
| `cn voice on claude` | Enable voice for Claude only                 |
| `cnp on`             | Enable for current project only              |

When enabling project notifications with `cnp on`, Code-Notify warns if Claude project trust does not appear to be accepted yet.
Project-scoped Claude hooks override the global mute file, so `cn off` will not suppress a project where `cnp on` is enabled.
`all` is also accepted as an explicit alias for global commands such as `cn on all`, `cn off all`, and `cn status all`.

## How It Works

Code-Notify uses the hook systems built into AI coding tools:

- **Claude Code**: `~/.claude/settings.json`
- **Codex**: `~/.codex/config.toml`
- **Gemini CLI**: `~/.gemini/settings.json`

For Codex, Code-Notify configures `notify = ["/absolute/path/to/notifier.sh", "codex"]` and reads the JSON payload Codex appends on completion.
Codex currently exposes completion events through `notify`; approval and `request_permissions` prompts do not currently arrive through this hook.

When enabled, it adds hooks that call the notification script when tasks complete:

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

### Alert Types

<img src="assets/cn-status-v1.4.0.png" width="60%" alt="cn status showing alert types"/>

By default, notifications only fire when the AI is idle and waiting for input (`idle_prompt`). You can customize this:

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

Alert-type matching applies to Claude Code notification hooks and Gemini CLI notification hooks. `ask_user` is a Claude-only `PreToolUse` hook for `AskUserQuestion`; it is applied immediately when Claude notifications are already enabled. Claude Code agent/team events are separate hook events and are opt-in via `cn alerts add SubagentStop`, `cn alerts add TeammateIdle`, or `cn alerts add TaskCompleted`.

Agent-team and subagent workflows can be noisy if `permission_prompt` is enabled. If you only want idle pings, run `cn alerts remove permission_prompt && cn on`. Codex currently uses completion events from `notify`, so `permission_prompt` and `idle_prompt` settings do not change Codex behavior.

### Slack And Discord

Code-Notify can also send the same notification to Slack or Discord through incoming webhooks. Desktop notifications still work normally; remote delivery is an extra channel.

```bash
cn channels add slack https://hooks.slack.com/services/...
cn channels add discord https://discord.com/api/webhooks/...
cn channels status
cn channels test all
```

Webhook URLs are stored locally in `~/.config/code-notify/channels.json` and are redacted in `cn status`.

### Usage Alerts

Usage alerts are opt-in for Codex and Claude:

```bash
cn usage on
cn usage check
cn usage watch --interval 300
cn usage thresholds set 20,10
cn usage reset-alerts voice on
cn usage reset-alerts sound default
```

Code-Notify checks the daily (5h) and weekly (7d) usage windows. It sends a warning when remaining usage crosses 20% or 10%, and sends a reset notification when a window returns to 100%.

Reset alerts are intentionally separate from normal task-complete alerts. By default they use a different title, voice message, and reset sound so it is clear that tokens have refilled. The voice message identifies the window, for example `Codex token daily limit reset` or `Codex token weekly limit reset`. You can disable or customize that behavior:

```bash
cn usage reset-alerts off
cn usage reset-alerts voice off
cn usage reset-alerts sound set ~/sounds/tokens-reset.wav
```

Codex usage checks read `~/.codex/auth.json`. Claude usage checks read `~/.claude/.credentials.json`. Code-Notify does not launch provider CLIs, start login flows, or install a background daemon.

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

**Installed with npm?**

```bash
cn update     # Runs: npm install -g code-notify@latest
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
- [GitHub Issues](https://github.com/mylee04/code-notify/issues)

## License

MIT License - see [LICENSE](LICENSE)
