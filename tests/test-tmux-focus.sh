#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

# Fake tmux that records invocations and answers display-message/list-clients
fake_bin="$test_dir/bin"
log_file="$test_dir/tmux-calls.log"
mkdir -p "$fake_bin"
cat > "$fake_bin/tmux" <<EOF
#!/bin/bash
echo "\$*" >> "$log_file"
args=("\$@")
has_target=0
for ((i = 0; i < \${#args[@]}; i++)); do
    [[ "\${args[i]}" == "-t" ]] && has_target=1
done
for ((i = 0; i < \${#args[@]}; i++)); do
    case "\${args[i]}" in
        display-message)
            echo "\$FAKE_TMUX_TARGET"
            exit 0
            ;;
        list-clients)
            # Session-filtered lookup (-t) and the unfiltered fallback return
            # separate fixtures so tests can drive each branch independently.
            if [[ "\$has_target" == 1 ]]; then
                echo "\$FAKE_TMUX_CLIENTS"
            else
                echo "\$FAKE_TMUX_ALL_CLIENTS"
            fi
            exit 0
            ;;
    esac
done
exit 0
EOF
chmod +x "$fake_bin/tmux"
export PATH="$fake_bin:$PATH"

source "$ROOT_DIR/lib/code-notify/utils/tmux.sh"

# --- shell quoting ---
[[ "$(tmux_focus_shell_quote "plain")" == "'plain'" ]] || fail "quote should wrap value in single quotes"
[[ "$(tmux_focus_shell_quote "a'b")" == "'a'\\''b'" ]] || fail "quote should escape embedded single quotes"
pass "shell quoting"

# --- not inside tmux ---
unset TMUX TMUX_PANE
if tmux_focus_build_command > /dev/null; then
    fail "build should fail outside tmux"
fi
pass "no-op outside tmux"

# --- happy path ---
export TMUX="$test_dir/sock,12345,0"
export TMUX_PANE="%3"
# shellcheck disable=SC2016  # $1 is a literal tmux session ID, not a parameter
export FAKE_TMUX_TARGET='$1 @2 %3'
export FAKE_TMUX_CLIENTS=""

cmd=$(tmux_focus_build_command) || fail "build should succeed inside tmux"
[[ "$cmd" == *"select-window -t '@2'"* ]] || fail "command should select window @2"
[[ "$cmd" == *"select-pane -t '%3'"* ]] || fail "command should select pane %3"
[[ "$cmd" == *"-S '$test_dir/sock'"* ]] || fail "command should target the captured socket"
[[ "$cmd" == *"switch-client"* ]] || fail "command should switch the attached client"
[[ "$cmd" != *"open -b"* ]] || fail "command should omit activation without a bundle id"
pass "focus command structure"

# --- bundle id activation ---
cmd=$(tmux_focus_build_command "com.googlecode.iterm2")
[[ "$cmd" == *"open -b 'com.googlecode.iterm2'"* ]] || fail "command should activate the bundle id"
pass "bundle id activation"

# --- generated command runs against tmux ---
: > "$log_file"
export FAKE_TMUX_CLIENTS="1718000000 client0"
cmd=$(tmux_focus_build_command)
/bin/sh -c "$cmd" > /dev/null 2>&1 || fail "generated command should run cleanly"
grep -q -- "select-window -t @2" "$log_file" || fail "runtime should call select-window"
grep -q -- "select-pane -t %3" "$log_file" || fail "runtime should call select-pane"
grep -q -- "switch-client -c client0 -t \$1" "$log_file" || fail "runtime should switch client0 to session \$1"
pass "generated command execution"

# --- most recently active client wins when several are attached ---
: > "$log_file"
export FAKE_TMUX_CLIENTS=$'100 stale-client\n300 recent-client\n200 middle-client'
cmd=$(tmux_focus_build_command)
/bin/sh -c "$cmd" > /dev/null 2>&1 || fail "generated command should run cleanly with multiple clients"
grep -q -- "switch-client -c recent-client -t \$1" "$log_file" || fail "runtime should pick the most recently active client"
pass "multi-client activity ordering"

# --- no client on the session falls back to the most recent client overall ---
: > "$log_file"
export FAKE_TMUX_CLIENTS=""
export FAKE_TMUX_ALL_CLIENTS=$'100 other-session-client\n250 fallback-client'
cmd=$(tmux_focus_build_command)
/bin/sh -c "$cmd" > /dev/null 2>&1 || fail "generated command should run cleanly when session has no client"
grep -q -- "switch-client -c fallback-client -t \$1" "$log_file" || fail "runtime should switch the most recently active client to the session"
pass "fallback to most recent client"

# --- unexpected target output is rejected ---
export FAKE_TMUX_TARGET='mysession; rm -rf / @2 %3'
if tmux_focus_build_command > /dev/null; then
    fail "build should reject non-ID session output"
fi
# shellcheck disable=SC2016  # $1 is a literal tmux session ID, not a parameter
export FAKE_TMUX_TARGET='$1 @2 %3x'
if tmux_focus_build_command > /dev/null; then
    fail "build should reject malformed pane IDs"
fi
pass "unsafe target rejection"

echo "All tmux focus tests passed"
