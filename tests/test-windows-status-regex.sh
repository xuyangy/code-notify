#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_INSTALLER="$SCRIPT_DIR/../scripts/install-windows.ps1"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# Guard against the previously-fixed bug: double-quoted PowerShell regexes that
# doubled their backslashes (e.g. "(?m)^\\s*\\[") and never matched at runtime.
if grep -qF '"(?m)^\\s*\\["' "$WINDOWS_INSTALLER"; then
    fail "broken double-quoted PowerShell regex is still present"
fi

# Codex TUI notification management parses config.toml line by line and must use
# single-quoted, PowerShell-safe patterns to detect TOML section headers.
if ! grep -qF "match '^\\s*\\['" "$WINDOWS_INSTALLER"; then
    fail "single-quoted TOML section regex is missing"
fi

if command -v pwsh >/dev/null 2>&1; then
    ps_script="$(mktemp)"
    trap 'rm -f "$ps_script"' EXIT
    cat > "$ps_script" <<'EOF'
$lines = @("notifications = true", "[tui]")
$sawSection = $false
foreach ($line in $lines) {
    if ($line -match '^\s*\[') { $sawSection = $true }
}
if (-not $sawSection) { exit 1 }
EOF
    if ! pwsh -NoProfile -File "$ps_script"; then
        fail "PowerShell-safe regex failed under pwsh"
    fi
fi

pass "Windows status regex uses a PowerShell-safe pattern"
