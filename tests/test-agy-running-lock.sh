#!/bin/bash

# agy_with_running_lock runs before every Antigravity model and tool call, so
# it must never hang the agent: an unwritable state directory or a live holder
# ends the wait with a failure (the callback is not run unlocked), a dead
# holder's lock is reclaimed quickly, and a pid-less leftover is reclaimed
# after the grace check.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="$SCRIPT_DIR/../lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

TEST_DIR="$(mktemp -d)"
trap 'chmod -R u+w "$TEST_DIR" 2>/dev/null; rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR/home"
state_dir="$HOME/.claude/notifications/agy"
mkdir -p "$state_dir"
lockdir="$state_dir/conv-lock.running.lock"
marker="$state_dir/conv-lock.running"
payload='{"conversationId":"conv-lock","workspacePaths":["/tmp/work/proj"]}'

# Runs PreInvocation (whose callback writes the running marker) and prints
# the elapsed whole seconds. Gives up after 20s so a hang fails instead of
# blocking the suite.
run_pre_invocation() {
    local start=$SECONDS pid
    printf '%s' "$payload" | env -u TMUX -u TMUX_PANE CODE_NOTIFY_TAIL_SYNC=1 \
        bash "$NOTIFIER" agy:PreInvocation antigravity &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if (( SECONDS - start > 20 )); then
            kill "$pid" 2>/dev/null || true
            echo "timeout"
            return 0
        fi
        sleep 0.1
    done
    echo $(( SECONDS - start ))
}

# Dead holder: reclaimed at the first owner check, callback runs.
rm -f "$marker"
mkdir "$lockdir"
printf '%s' "999999" > "$lockdir/pid"
elapsed="$(run_pre_invocation)"
[[ "$elapsed" != "timeout" ]] && (( elapsed <= 3 )) || fail "a dead holder's lock took ${elapsed}s to reclaim"
[[ -f "$marker" ]] || fail "the callback did not run after reclaiming a dead holder's lock"
[[ ! -d "$lockdir" ]] || fail "the reclaimed lock was left behind"
pass "a dead holder's lock is reclaimed quickly"

# Pid-less leftover: reclaimed on the second owner check.
rm -f "$marker"
mkdir "$lockdir"
elapsed="$(run_pre_invocation)"
[[ "$elapsed" != "timeout" ]] && (( elapsed <= 4 )) || fail "a pid-less lock took ${elapsed}s to reclaim"
[[ -f "$marker" ]] || fail "the callback did not run after reclaiming a pid-less lock"
pass "a pid-less leftover lock is reclaimed after the grace check"

# Live holder: the wait ends with a failure, the callback does not run, and
# the holder's lock is untouched.
rm -f "$marker"
sleep 30 &
holder=$!
mkdir "$lockdir"
printf '%s' "$holder" > "$lockdir/pid"
elapsed="$(run_pre_invocation)"
kill "$holder" 2>/dev/null || true
[[ "$elapsed" != "timeout" ]] && (( elapsed <= 8 )) || fail "a live holder kept the hook waiting ${elapsed}s"
[[ ! -f "$marker" ]] || fail "the callback ran without the lock"
[[ "$(cat "$lockdir/pid" 2>/dev/null)" == "$holder" ]] || fail "the live holder's lock was taken over"
rm -rf "$lockdir"
pass "a live holder bounds the wait and keeps its lock"

# Unwritable state directory: the lock can never be taken, so the wait ends
# at the first owner check instead of spinning.
rm -f "$marker"
chmod 555 "$state_dir"
elapsed="$(run_pre_invocation)"
chmod 755 "$state_dir"
[[ "$elapsed" != "timeout" ]] && (( elapsed <= 3 )) || fail "an unwritable state directory kept the hook waiting ${elapsed}s"
pass "an unwritable state directory ends the wait"
