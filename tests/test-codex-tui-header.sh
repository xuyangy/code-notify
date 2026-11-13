#!/bin/bash

# A [tui] table header written with a trailing comment or with spaces inside
# the brackets is still the [tui] table: enabling Codex must put its managed
# setting there instead of appending a second [tui] (invalid TOML), and
# disabling must leave the original table as it was.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR/home"
mkdir -p "$HOME/.codex"

source "$LIB_DIR/core/config.sh"

# Parses with tomllib when this python3 has it (3.11+); otherwise only the
# header count is checked.
toml_valid() {
    local file="$1"
    python3 - "$file" <<'PY' 2>/dev/null
import sys
try:
    import tomllib
except ImportError:
    sys.exit(0)
with open(sys.argv[1], "rb") as fh:
    tomllib.load(fh)
PY
}

check_header() {
    local label="$1" header="$2"
    local file="$HOME/.codex/config.toml"
    local original

    printf '%s\n' 'model = "gpt-5"' '' "$header" 'theme = "dark"' 'notifications = true' > "$file"
    original="$(cat "$file")"

    disable_codex_tui_notifications "$file"
    [[ "$(grep -cE '^[[:space:]]*\[[[:space:]]*tui[[:space:]]*\]' "$file")" == "1" ]] \
        || fail "$label: enabling Codex added a second [tui] table"
    grep -qx 'notifications = false' "$file" || fail "$label: managed notifications = false was not written"
    toml_valid "$file" || fail "$label: config.toml is not valid TOML after enabling Codex"

    remove_codex_tui_notifications_override "$file"
    [[ "$(cat "$file")" == "$original" ]] || fail "$label: disabling Codex did not restore the original config"
    pass "$label"
}

check_header "[tui] with a trailing comment" '[tui] # ui settings'
check_header "[ tui ] with spaces inside the brackets" '[ tui ]'
check_header "plain [tui]" '[tui]'
