#!/bin/bash
#
# opencode compatibility plugins (oh-my-openagent) replay Claude Code hooks
# from settings.json inside opencode's process. opencode is not a supported
# agent: its replayed UserPromptSubmit would start the tmux spinner that no
# compatible turn-end ever clears. opencode exports OPENCODE=1/OPENCODE_PID
# into every process it spawns, so the notifier must exit before touching any
# badge, spinner, or notification state when either is present — while a
# hook process without them (Claude Code in a sibling window) keeps working.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
NOTIFIER="$ROOT_DIR/lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

# Fake tmux on PATH that only records its invocations: any call at all proves
# the notifier reached tmux state handling.
fake_bin="$test_dir/bin"
log_file="$test_dir/tmux-calls.log"
mkdir -p "$fake_bin"
cat > "$fake_bin/tmux" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_TMUX_LOG"
exit 0
EOF
chmod +x "$fake_bin/tmux"

export PATH="$fake_bin:$PATH"
export FAKE_TMUX_LOG="$log_file"
export HOME="$test_dir/home"
mkdir -p "$HOME"
export TMUX="$test_dir/fake-sock,1234,0"
export TMUX_PANE="%5"

# Never inherited from the environment running this test suite.
unset OPENCODE OPENCODE_PID

run_notifier() {
    "$NOTIFIER" "$@" < /dev/null > /dev/null 2>&1
}

# --- Control: without OPENCODE the prompt-submit path reaches tmux -----------
: > "$log_file"
run_notifier UserPromptSubmit claude || fail "control: notifier errored"
[[ -s "$log_file" ]] || fail "control: UserPromptSubmit never reached tmux (test harness broken?)"
pass "control: UserPromptSubmit reaches tmux without OPENCODE"

# --- OPENCODE=1 suppresses the spinner start ---------------------------------
: > "$log_file"
OPENCODE=1 run_notifier UserPromptSubmit claude || fail "OPENCODE: notifier exited nonzero"
[[ -s "$log_file" ]] && fail "OPENCODE: UserPromptSubmit still touched tmux"
pass "OPENCODE=1 suppresses UserPromptSubmit spinner start"

# --- OPENCODE_PID alone suppresses too ----------------------------------------
: > "$log_file"
OPENCODE_PID=4242 run_notifier UserPromptSubmit claude || fail "OPENCODE_PID: notifier exited nonzero"
[[ -s "$log_file" ]] && fail "OPENCODE_PID: UserPromptSubmit still touched tmux"
pass "OPENCODE_PID suppresses UserPromptSubmit spinner start"

# --- Other hook types are suppressed before any state is written -------------
: > "$log_file"
for hook in stop notification PostToolUse PreToolUse; do
    OPENCODE=1 run_notifier "$hook" claude || fail "OPENCODE: '$hook' exited nonzero"
done
[[ -s "$log_file" ]] && fail "OPENCODE: some hook still touched tmux"
[[ -e "$HOME/.claude/notifications" ]] && fail "OPENCODE: notification state was created"
pass "OPENCODE=1 suppresses stop/notification/tool hooks without writing state"

echo "All opencode suppression tests passed"
