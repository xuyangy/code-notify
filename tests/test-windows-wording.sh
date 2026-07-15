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

    Invoke-WordingCommand -Target "banner" -Style "reset" | Out-Null
    if (Test-Path $bannerFile) { throw "reset should remove the state file" }

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

    foreach ($fn in @("Get-WordingStyle", "Select-WordedMessage")) {
        if ($notify -notmatch "(?ms)^(?<body>function $fn.*?^\})") {
            throw "could not extract $fn from notify script"
        }
        Invoke-Expression $Matches['body']
    }
    if ((Get-WordingStyle -Target "banner" -Default "short") -ne "short") { throw "banner should default to short" }
    if ((Get-WordingStyle -Target "voice" -Default "long") -ne "long") { throw "voice should default to long" }

    New-Item -ItemType Directory -Path $script:NotificationsDir -Force | Out-Null
    $bannerFile = Join-Path $script:NotificationsDir "wording-banner"
    Set-Content -Path $bannerFile -Value "long"
    if ((Get-WordingStyle -Target "banner" -Default "short") -ne "long") { throw "banner should follow the state file" }

    $env:CODE_NOTIFY_BANNER_WORDING = "short"
    if ((Get-WordingStyle -Target "banner" -Default "short") -ne "short") { throw "env var should override the state file" }
    $env:CODE_NOTIFY_BANNER_WORDING = $null

    Set-Content -Path $bannerFile -Value "sonnet-form"
    if ((Get-WordingStyle -Target "banner" -Default "short") -ne "short") { throw "garbage in the state file should fall back to the default" }

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
