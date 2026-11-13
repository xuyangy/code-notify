#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_INSTALLER="$SCRIPT_DIR/../scripts/install-windows.ps1"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

if ! command -v pwsh >/dev/null 2>&1; then
    pass "pwsh not installed; skipping Windows Claude hook preservation test"
    exit 0
fi

ps_script="$(mktemp)"
trap 'rm -f "$ps_script"' EXIT

cat > "$ps_script" <<'EOF'
param([string]$InstallerPath)

$ErrorActionPreference = "Stop"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("code-notify-win-" + [guid]::NewGuid().ToString())

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $env:USERPROFILE = $testRoot

    $content = Get-Content -Raw $InstallerPath
    # Single-quoted: a double-quoted string would expand $mainScript and
    # collapse the regex to match the first heredoc in the file.
    if ($content -notmatch '(?ms)\$mainScript = @''\r?\n(?<module>.*?)\r?\n''@') {
        throw "could not extract Code-Notify PowerShell module from installer"
    }
    $moduleScript = $Matches['module']
    $moduleScript = $moduleScript -replace '(?ms)\r?\nExport-ModuleMember -Function @\(.*?\)\s*$', ''
    Invoke-Expression $moduleScript

    $script:ClaudeHome = Join-Path $env:USERPROFILE ".claude"
    $script:DefaultSettingsFile = Join-Path $script:ClaudeHome "settings.json"
    $script:AlternateSettingsFile = Join-Path (Join-Path $env:USERPROFILE ".config\.claude") "settings.json"
    $script:SettingsFile = $script:DefaultSettingsFile
    $script:NotificationsDir = Join-Path $script:ClaudeHome "notifications"
    $script:NotifyTypesFile = Join-Path $script:NotificationsDir "notify-types"
    $script:VoiceFile = Join-Path $script:NotificationsDir "voice-enabled"
    $script:SoundEnabledFile = Join-Path $script:NotificationsDir "sound-enabled"
    $script:SoundCustomFile = Join-Path $script:NotificationsDir "sound-custom"
    $script:LogsDir = Join-Path $script:ClaudeHome "logs"

    function Send-Notification { param([string]$Title, [string]$Message, [string]$Type) }
    function Write-ClaudeProjectTrustWarning { param([string]$ProjectRoot) }

    New-Item -ItemType Directory -Path $script:ClaudeHome, $script:NotificationsDir, $script:LogsDir -Force | Out-Null

    @'
{
  "hooks": {
    "Notification": [
      {
        "matcher": "custom_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "echo custom notification"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "echo pre"
          }
        ]
      }
    ]
  },
  "theme": "dark"
}
'@ | Set-Content $script:SettingsFile -Encoding UTF8

    if (Test-NotificationsEnabled -Tool "claude") {
        throw "custom Claude hooks were incorrectly treated as current code-notify hooks"
    }

    Enable-Notifications -Tool "claude"

    $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
    $notifyCommand = Get-ClaudeNotifyCommand -NotifyScript (Get-NotifyScript)
    $stopCommand = Get-ClaudeStopCommand -NotifyScript (Get-NotifyScript)
    $stopFailureCommand = Get-ClaudeStopFailureCommand -NotifyScript (Get-NotifyScript)

    if (-not $settings.hooks.PSObject.Properties['PreToolUse']) {
        throw "PreToolUse hook was removed during enable"
    }
    if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.Notification) -Matcher "custom_prompt" -Command "echo custom notification")) {
        throw "custom Notification hook was removed during enable"
    }
    if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.Notification) -Matcher "idle_prompt" -Command $notifyCommand)) {
        throw "current Claude Notification hook was not added"
    }
    if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.Stop) -Matcher "" -Command $stopCommand)) {
        throw "current Claude Stop hook was not added"
    }
    if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.StopFailure) -Matcher "" -Command $stopFailureCommand)) {
        throw "current Claude StopFailure hook was not added"
    }
    if ($settings.hooks.PSObject.Properties['PermissionRequest']) {
        throw "PermissionRequest should not be installed when permission_prompt is disabled"
    }
    foreach ($eventType in @("SubagentStop", "TeammateIdle")) {
        $eventCommand = Get-ClaudeEventCommand -NotifyScript (Get-NotifyScript) -EventType $eventType
        if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.$eventType) -Matcher "" -Command $eventCommand)) {
            throw "retirement hook $eventType was not installed"
        }
    }
    if ($settings.hooks.PSObject.Properties['SubagentStart']) {
        throw "SubagentStart should not be installed when its alert type is disabled"
    }

    "idle_prompt|permission_prompt" | Set-Content $script:NotifyTypesFile -Encoding ASCII
    Enable-Notifications -Tool "claude"
    $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
    if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.PermissionRequest) -Matcher "" -Command $notifyCommand)) {
        throw "permission_prompt did not install the immediate Claude PermissionRequest hook"
    }
    if (Test-HookEntriesContainCommand -Entries @($settings.hooks.Notification) -Matcher "permission_prompt" -Command $notifyCommand) {
        throw "permission_prompt should not use Claude's delayed Notification event"
    }

    Disable-Notifications -Tool "claude"

    $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $settings.hooks.PSObject.Properties['PreToolUse']) {
        throw "PreToolUse hook was removed during disable"
    }
    if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.Notification) -Matcher "custom_prompt" -Command "echo custom notification")) {
        throw "custom Notification hook was removed during disable"
    }
    if ($settings.hooks.PSObject.Properties['Stop']) {
        throw "managed Stop hook should be removed during disable"
    }
    if ($settings.hooks.PSObject.Properties['StopFailure']) {
        throw "managed StopFailure hook should be removed during disable"
    }
    if ($settings.hooks.PSObject.Properties['PermissionRequest']) {
        throw "managed PermissionRequest hook should be removed during disable"
    }
    foreach ($eventType in @("SubagentStop", "TeammateIdle")) {
        if ($settings.hooks.PSObject.Properties[$eventType]) {
            throw "managed $eventType hook should be removed during disable"
        }
    }
    if (Test-HookEntriesContainCommand -Entries @($settings.hooks.Notification) -Matcher "idle_prompt" -Command $notifyCommand) {
        throw "managed Notification hook should be removed during disable"
    }

    Remove-Item $script:SettingsFile -Force -ErrorAction SilentlyContinue

    Enable-Notifications -Tool "claude"
    $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $settings.hooks) {
        throw "managed hooks were not created for the clean settings case"
    }

    Disable-Notifications -Tool "claude"
    if (Test-Path $script:SettingsFile) {
        $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($settings.hooks) {
            throw "hooks should be removed entirely when only managed Claude hooks existed"
        }
    }

    # A user's own hook that runs some other notify.ps1 / notify.sh is theirs;
    # only the notify script in the default .claude\notifications location is
    # code-notify's.
    $legacyCommand = 'powershell -ExecutionPolicy Bypass -File "C:\Users\old\.claude\notifications\notify.ps1" stop claude'
    $userPsCommand = 'powershell -File "C:\Users\me\scripts\notify.ps1" stop'
    $userProjectCommand = 'powershell -File "C:\my-project\notifications\notify.ps1" stop'
    $userShCommand = '/Users/me/bin/notify.sh stop'
    @{
        hooks = @{
            Stop = @(
                @{ hooks = @(@{ type = "command"; command = $userPsCommand }) },
                @{ hooks = @(@{ type = "command"; command = $userProjectCommand }) },
                @{ hooks = @(@{ type = "command"; command = $userShCommand }) },
                @{ hooks = @(@{ type = "command"; command = $legacyCommand }) }
            )
        }
    } | ConvertTo-Json -Depth 10 | Set-Content $script:SettingsFile -Encoding UTF8

    Enable-Notifications -Tool "claude"
    $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
    foreach ($userCommand in @($userPsCommand, $userProjectCommand, $userShCommand)) {
        if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.Stop) -Matcher "" -Command $userCommand)) {
            throw "enable removed a user Stop hook: $userCommand"
        }
    }
    if (Test-HookEntriesContainCommand -Entries @($settings.hooks.Stop) -Matcher "" -Command $legacyCommand) {
        throw "enable kept the legacy notifications\notify.ps1 Stop hook"
    }
    Disable-Notifications -Tool "claude"
    $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
    foreach ($userCommand in @($userPsCommand, $userProjectCommand, $userShCommand)) {
        if (-not (Test-HookEntriesContainCommand -Entries @($settings.hooks.Stop) -Matcher "" -Command $userCommand)) {
            throw "disable removed a user Stop hook: $userCommand"
        }
    }

    # Codex config.toml: a user notify program called notify.sh is kept; the
    # legacy code-notify assignment (Windows backslash path) is removed.
    $tomlPath = Join-Path $testRoot "config.toml"
    @('model = "gpt-5"', 'notify = ["bash", "/Users/me/.codex/notify.sh"]') | Set-Content $tomlPath -Encoding UTF8
    Remove-CodexNotifyConfig -Path $tomlPath
    if (-not ((Get-Content $tomlPath -Raw) -match [regex]::Escape('notify = ["bash", "/Users/me/.codex/notify.sh"]'))) {
        throw "Remove-CodexNotifyConfig removed a user notify program called notify.sh"
    }
    @('model = "gpt-5"', 'notify = ["powershell", "C:\\Users\\old\\.claude\\notifications\\notify.ps1", "codex"]') | Set-Content $tomlPath -Encoding UTF8
    Remove-CodexNotifyConfig -Path $tomlPath
    if ((Get-Content $tomlPath -Raw) -match '(?m)^\s*notify\s*=') {
        throw "Remove-CodexNotifyConfig kept the legacy code-notify notify assignment"
    }

    # Gemini: the user's own AfterAgent hook and their hooks.enabled survive
    # enable and disable; only code-notify's hooks are added and removed.
    $script:GeminiHome = Join-Path $env:USERPROFILE ".gemini"
    $script:GeminiSettingsFile = Join-Path $script:GeminiHome "settings.json"
    New-Item -ItemType Directory -Path $script:GeminiHome -Force | Out-Null
    $userGeminiCommand = 'C:\tools\my-logger.exe'
    @{
        theme = "x"
        hooks = @{
            enabled = $true
            AfterAgent = @(@{ matcher = ""; hooks = @(@{ name = "code-notify-complete"; type = "command"; command = $userGeminiCommand }) })
        }
    } | ConvertTo-Json -Depth 10 | Set-Content $script:GeminiSettingsFile -Encoding UTF8
    if (Test-NotificationsEnabled -Tool "gemini") {
        throw "a user Gemini hook was treated as code-notify's"
    }
    Enable-Notifications -Tool "gemini"
    $gemini = Get-Content $script:GeminiSettingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
    $geminiStop = Get-GeminiStopCommand -NotifyScript (Get-NotifyScript)
    if (-not (Test-HookEntriesContainCommand -Entries @($gemini.hooks.AfterAgent) -Matcher "" -Command $userGeminiCommand)) {
        throw "Gemini enable removed the user's AfterAgent hook"
    }
    if (-not (Test-HookEntriesContainCommand -Entries @($gemini.hooks.AfterAgent) -Matcher "" -Command $geminiStop)) {
        throw "Gemini enable did not add the AfterAgent hook"
    }
    if (-not (Test-NotificationsEnabled -Tool "gemini")) {
        throw "enabled Gemini settings did not read as enabled"
    }
    Disable-Notifications -Tool "gemini"
    $gemini = Get-Content $script:GeminiSettingsFile -Raw | ConvertFrom-Json -ErrorAction Stop
    if (-not (Test-HookEntriesContainCommand -Entries @($gemini.hooks.AfterAgent) -Matcher "" -Command $userGeminiCommand)) {
        throw "Gemini disable removed the user's AfterAgent hook"
    }
    if (Test-HookEntriesContainCommand -Entries @($gemini.hooks.AfterAgent) -Matcher "" -Command $geminiStop) {
        throw "Gemini disable kept the code-notify AfterAgent hook"
    }
    if ($gemini.hooks.enabled -ne $true -or $gemini.theme -ne "x") {
        throw "Gemini disable dropped hooks.enabled or other settings while user hooks remain"
    }
}
finally {
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
EOF

if ! pwsh -NoProfile -File "$ps_script" "$WINDOWS_INSTALLER"; then
    fail "Windows Claude hook preservation behavior regressed"
fi

pass "Windows Claude hook detection and preservation stay aligned"
