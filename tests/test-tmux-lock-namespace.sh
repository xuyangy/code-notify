#!/bin/bash

# The tmux transition lock picks its directory once. If a mkdir fails because
# a holder held the lock, and that holder releases before the waiter looks
# again, the waiter must retry in the same directory: switching to the
# fallback directory there would let it hold a lock while another process
# holds the same window's lock in the primary directory.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR/home"
mkdir -p "$HOME/.claude/notifications/state" "$TEST_DIR/sock"
chmod 700 "$TEST_DIR/sock"
export TMUX="$TEST_DIR/sock/default,123,0"
export TMUX_PANE="%3"

(
    source "$LIB_DIR/utils/tmux.sh"
    primary="$TMUX_RUNNING_LOCK_DIR"
    command mkdir -p "$primary"

    # The first mkdir of the lock fails as if another process held it, and
    # that process has already released by the time the waiter checks, so no
    # lock directory is left behind. Later mkdirs behave normally.
    lock_mkdir_calls=0
    mkdir() {
        if [[ "${!#}" == *".lock" ]] && (( lock_mkdir_calls == 0 )); then
            lock_mkdir_calls=1
            return 1
        fi
        command mkdir "$@"
    }

    tmux_running_transition_lock_acquire "@2" || fail "the lock was not acquired after the holder released"
    [[ "$TMUX_RUNNING_TRANSITION_LOCKDIR" == "$primary/"* ]] \
        || fail "the waiter switched lock directories: $TMUX_RUNNING_TRANSITION_LOCKDIR"
    tmux_running_transition_lock_release "$TMUX_RUNNING_TRANSITION_LOCKDIR" "$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
) < /dev/null
pass "a waiter whose holder just released retries in the same lock directory"

# A directory that keeps rejecting mkdir ends in a bounded failure, not a
# switch to another directory.
(
    source "$LIB_DIR/utils/tmux.sh"
    command mkdir -p "$TMUX_RUNNING_LOCK_DIR"
    # shellcheck disable=SC2034  # read by tmux_running_transition_lock_acquire
    TMUX_RUNNING_LOCK_TIMEOUT_MS=200
    mkdir() {
        if [[ "${!#}" == *".lock" ]]; then
            return 1
        fi
        command mkdir "$@"
    }
    start=$SECONDS
    if tmux_running_transition_lock_acquire "@2"; then
        fail "a directory that rejects every mkdir still produced a lock: $TMUX_RUNNING_TRANSITION_LOCKDIR"
    fi
    (( SECONDS - start <= 3 )) || fail "a rejecting directory kept the waiter for $((SECONDS - start))s"
) < /dev/null
pass "a directory that rejects mkdir fails within the timeout"
