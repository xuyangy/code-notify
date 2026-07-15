#!/bin/bash

# Wording styles: banner and voice each pick from the short (terse) or long
# (friendly) message pool, banner defaulting to short and voice to long.
# Covers the `cn wording` state files, the env overrides, and the reset path.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
NOTIFIER="$ROOT_DIR/lib/code-notify/core/notifier.sh"
CN="$ROOT_DIR/bin/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

os_name="$(uname -s)"
case "$os_name" in
    Darwin|Linux) ;;
    *)
        echo "SKIP: unsupported OS for wording style test"
        exit 0
        ;;
esac

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
banner_log="$test_dir/banner.log"
say_log="$test_dir/say.log"
mkdir -p "$HOME/.claude/notifications" "$HOME/.claude/logs" "$fake_bin"

if [[ "$os_name" == "Darwin" ]]; then
    cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "-help" ]]; then exit 0; fi
printf '%s\n' "\$*" >> "$banner_log"
EOF
else
    cat > "$fake_bin/notify-send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$banner_log"
EOF
fi
cat > "$fake_bin/say" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$say_log"
EOF
chmod +x "$fake_bin"/*
fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Enable spoken messages: the voice file both turns speech on for the tool
# and names the `say` voice the stub receives.
printf 'TestVoice\n' > "$HOME/.claude/notifications/voice-claude"

# stop banner pools (see notifier.sh): the long pool is recognizable by its
# exclamation openers and "your task/request" phrasing.
short_re='Claude (completed the task|finished the task|is done|wrapped up)'
long_re='(All done!|finished working on your request|Task complete!|Good news!|Finished!)'

run_stop() {
    : > "$banner_log"
    : > "$say_log"
    # Each run must notify: drop the rate-limit state from the previous one.
    rm -rf "$HOME/.claude/notifications/state"
    printf '{}' | PATH="$fake_path" bash "$NOTIFIER" stop claude wording-test
    # The voice branch runs disowned in the background; give it a moment.
    for _ in $(seq 1 40); do
        [[ -s "$say_log" ]] && break
        sleep 0.05
    done
}

banner_matches() { grep -Eq "$1" "$banner_log"; }
say_matches() { [[ -f "$say_log" ]] && grep -Eq "$1" "$say_log"; }

# --- defaults: banner short, voice long ---
run_stop
banner_matches "$short_re" || fail "default banner should use the short pool"
banner_matches "$long_re" && fail "default banner must not use the long pool"
say_matches "$long_re" || fail "default voice should use the long pool"
say_matches 'Project wording test' || fail "voice should speak the project name with separators as spaces"

# --- cn wording writes state files the notifier honours ---
PATH="$fake_path" "$CN" wording banner long >/dev/null
[[ "$(cat "$HOME/.claude/notifications/wording-banner")" == "long" ]] ||
    fail "cn wording banner long should write the state file"
run_stop
banner_matches "$long_re" || fail "banner should follow wording-banner=long"

PATH="$fake_path" "$CN" wording voice short >/dev/null
run_stop
say_matches "$short_re" || fail "voice should follow wording-voice=short"
say_matches "$long_re" && fail "voice set to short must not use the long pool"

# --- env vars override the state files ---
: > "$banner_log"
rm -rf "$HOME/.claude/notifications/state"
printf '{}' | PATH="$fake_path" CODE_NOTIFY_BANNER_WORDING=short \
    bash "$NOTIFIER" stop claude wording-test
banner_matches "$short_re" || fail "CODE_NOTIFY_BANNER_WORDING should override the state file"
banner_matches "$long_re" && fail "env-overridden banner must not use the long pool"

# --- reset removes the state files (defaults return) ---
PATH="$fake_path" "$CN" wording banner reset >/dev/null
PATH="$fake_path" "$CN" wording voice reset >/dev/null
[[ ! -f "$HOME/.claude/notifications/wording-banner" ]] ||
    fail "reset should remove the banner state file"
run_stop
banner_matches "$short_re" || fail "banner should be short again after reset"
say_matches "$long_re" || fail "voice should be long again after reset"

# --- garbage in the state file falls back to the default ---
printf 'sonnet-form\n' > "$HOME/.claude/notifications/wording-banner"
run_stop
banner_matches "$short_re" || fail "unrecognized style should fall back to the default"

# --- status reports both targets ---
status_out="$(PATH="$fake_path" "$CN" wording status)"
printf '%s' "$status_out" | grep -q "banner wording" || fail "status should report banner wording"
printf '%s' "$status_out" | grep -q "voice wording" || fail "status should report voice wording"

pass "wording styles"
