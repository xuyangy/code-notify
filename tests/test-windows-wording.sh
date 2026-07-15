#!/bin/bash

# Windows wording styles: `cn wording` must write the state files the Windows
# notifier reads, and the notifier's Get-WordingStyle/Select-WordedMessage
# must honour files, env overrides, and the defaults (banner short, voice
# long). Skips when pwsh is unavailable.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_INSTALLER="$SCRIPT_DIR/../scripts/install-windows.ps1"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

if ! command -v pwsh >/dev/null 2>&1; then
    pass "pwsh not installed; skipping Windows wording test"
    exit 0
fi

ps_script="$(mktemp)"
trap 'rm -f "$ps_script"' EXIT

cat > "$ps_script" <<'EOF'
param([string]$InstallerPath)

$ErrorActionPreference = "Stop"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("code-notify-wording-" + [guid]::NewGuid().ToString())

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $env:USERPROFILE = $testRoot
    $env:CLAUDE_HOME = $null

    $content = Get-Content -Raw $InstallerPath

    # --- CLI: Invoke-WordingCommand manages the state files ---
    if ($content -notmatch "(?ms)\$mainScript = @'\r?\n(?<module>.*?)\r?\n'@") {
        throw "could not extract Code-Notify PowerShell module from installer"
    }
    $moduleScript = $Matches['module']
    $moduleScript = $moduleScript -replace '(?ms)\r?\nExport-ModuleMember -Function @\(.*?\)\s*$', ''
    Invoke-Expression $moduleScript

    $script:ClaudeHome = Join-Path $env:USERPROFILE ".claude"
    $script:NotificationsDir = Join-Path $script:ClaudeHome "notifications"
    $bannerFile = Join-Path $script:NotificationsDir "wording-banner"

    Invoke-WordingCommand -Target "banner" -Style "long" | Out-Null
    if (-not (Test-Path $bannerFile)) { throw "cn wording banner long did not write the state file" }
    if ((Get-Content $bannerFile -TotalCount 1).Trim() -ne "long") { throw "state file should contain 'long'" }

    $status = Invoke-WordingCommand -Target "status" 6>&1 | Out-String
    if ($status -notmatch "banner wording") { throw "status should report banner wording" }
    if ($status -notmatch "voice wording") { throw "status should report voice wording" }
    if ($status -notmatch "banner project name") { throw "status should report the banner project toggle" }
    if ($status -notmatch "voice project name") { throw "status should report the voice project toggle" }

    Invoke-WordingCommand -Target "banner" -Style "reset" | Out-Null
    if (Test-Path $bannerFile) { throw "reset should remove the state file" }

    # --- CLI: project name toggles write their own state files ---
    $projectVoiceFile = Join-Path $script:NotificationsDir "wording-project-voice"
    Invoke-WordingCommand -Target "project" -Style "voice" -Toggle "off" | Out-Null
    if (-not (Test-Path $projectVoiceFile)) { throw "cn wording project voice off should write the state file" }
    if ((Get-Content $projectVoiceFile -TotalCount 1).Trim() -ne "off") { throw "project-voice state file should contain 'off'" }
    Invoke-WordingCommand -Target "project" -Style "voice" -Toggle "reset" | Out-Null
    if (Test-Path $projectVoiceFile) { throw "project reset should remove the state file" }

    # --- Notifier: style resolution helpers from the notify script ---
    if ($content -notmatch "(?ms)\$notifyScript = @'\r?\n(?<notify>.*?)\r?\n'@") {
        throw "could not extract notify script from installer"
    }
    $notify = $Matches['notify']

    # The CLI writes wording state under CLAUDE_HOME when set; verify that
    # behavior before checking that the notifier resolves the same root.
    $customClaudeHome = Join-Path $testRoot "custom-claude-home"
    $env:CLAUDE_HOME = $customClaudeHome
    $script:ClaudeHome = if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { "$env:USERPROFILE\.claude" }
    $script:NotificationsDir = Join-Path $script:ClaudeHome "notifications"
    $customVoiceFile = Join-Path $script:NotificationsDir "wording-voice"
    Invoke-WordingCommand -Target "voice" -Style "short" | Out-Null
    if (-not (Test-Path $customVoiceFile)) { throw "cn wording should write state under CLAUDE_HOME" }
    Invoke-WordingCommand -Target "voice" -Style "reset" | Out-Null

    # The notifier must resolve its state root the same way or the setting
    # never applies.
    if ($notify -notmatch '(?m)^\$ClaudeHome = if \(\$env:CLAUDE_HOME\)') {
        throw "notify script should resolve ClaudeHome from CLAUDE_HOME"
    }
    $claudeHomeAssignment = [regex]::Match($notify, '(?m)^\$ClaudeHome = if \(\$env:CLAUDE_HOME\).*').Value
    Invoke-Expression $claudeHomeAssignment
    if ($ClaudeHome -ne $customClaudeHome) { throw "notifier should read wording state from CLAUDE_HOME" }

    foreach ($fn in @("Get-WordingStyle", "Select-WordedMessage", "Get-ProjectWordingEnabled")) {
        if ($notify -notmatch "(?ms)^(?<body>function $fn.*?^\})") {
            throw "could not extract $fn from notify script"
        }
        Invoke-Expression $Matches['body']
    }
    if ((Get-WordingStyle -Target "banner" -Default "short") -ne "short") { throw "banner should default to short" }
    if ((Get-WordingStyle -Target "voice" -Default "long") -ne "long") { throw "voice should default to long" }

    # The notifier must strip the embedded project per target when toggled off.
    if ($notify -notmatch [regex]::Escape('$Message.Replace(" in $ProjectName", "")')) {
        throw "notify script should strip the project from the banner message when toggled off"
    }
    if ($notify -notmatch [regex]::Escape('$VoiceMessage.Replace(" in $ProjectName", "")')) {
        throw "notify script should strip the project from the voice message when toggled off"
    }

    # When the voice toggle is on, the spoken message must phrase the project
    # as "in project <name>" with the name hyphenated, matching the bash
    # notifier.
    if ($notify -notmatch [regex]::Escape('$ProjectName -replace ''_'', ''-''')) {
        throw "notify script should speak underscores as hyphens"
    }
    if ($notify -notmatch [regex]::Escape('" in project $spokenProject"')) {
        throw "notify script should speak the project as 'in project <name>'"
    }
    if (-not (Get-ProjectWordingEnabled -Target "banner")) { throw "banner project should default to on" }
    if (-not (Get-ProjectWordingEnabled -Target "voice")) { throw "voice project should default to on" }

    New-Item -ItemType Directory -Path $script:NotificationsDir -Force | Out-Null
    $bannerFile = Join-Path $script:NotificationsDir "wording-banner"
    Set-Content -Path $bannerFile -Value "long"
    if ((Get-WordingStyle -Target "banner" -Default "short") -ne "long") { throw "banner should follow the state file" }

    $env:CODE_NOTIFY_BANNER_WORDING = "short"
    if ((Get-WordingStyle -Target "banner" -Default "short") -ne "short") { throw "env var should override the state file" }
    $env:CODE_NOTIFY_BANNER_WORDING = $null

    Set-Content -Path $bannerFile -Value "sonnet-form"
    if ((Get-WordingStyle -Target "banner" -Default "short") -ne "short") { throw "garbage in the state file should fall back to the default" }

    $projectBannerFile = Join-Path $script:NotificationsDir "wording-project-banner"
    Set-Content -Path $projectBannerFile -Value "off"
    if (Get-ProjectWordingEnabled -Target "banner") { throw "banner project should follow the state file" }
    if (-not (Get-ProjectWordingEnabled -Target "voice")) { throw "voice project should stay on while only banner is off" }
    $env:CODE_NOTIFY_BANNER_PROJECT = "on"
    if (-not (Get-ProjectWordingEnabled -Target "banner")) { throw "env var should override the project state file" }
    $env:CODE_NOTIFY_BANNER_PROJECT = $null
    Remove-Item $projectBannerFile -Force

    $short = @("terse one", "terse two")
    $long = @("friendly one", "friendly two")
    if ($short -notcontains (Select-WordedMessage -Short $short -Long $long -Style "short")) { throw "short style should pick from the short pool" }
    if ($long -notcontains (Select-WordedMessage -Short $short -Long $long -Style "long")) { throw "long style should pick from the long pool" }

    Write-Output "OK"
} finally {
    Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
}
EOF

output="$(pwsh -NoProfile -File "$ps_script" "$WINDOWS_INSTALLER")" ||
    fail "pwsh wording test failed: $output"
[[ "$output" == *"OK"* ]] || fail "unexpected output: $output"

pass "Windows wording styles"
