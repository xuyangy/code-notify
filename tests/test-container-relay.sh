#!/bin/bash

# Container relay (pi, omp): spool records in, notifier invocations out.
#
# The relay is the whole bridge for containerized agents — the in-container
# hook can only write files — so what is asserted here is the mapping itself:
# every event reaches the notifier with the argv the notifier's generic path
# expects, unknown events stay silent, and a hostile record cannot become a
# command.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/../bin/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

TEST_ROOT="$(mktemp -d)"
cleanup() {
    [[ -n "${RELAY_PID:-}" ]] && kill "$RELAY_PID" 2>/dev/null
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

SPOOL="$TEST_ROOT/spool"
LOG="$TEST_ROOT/dispatch.log"
STUB="$TEST_ROOT/stub-notifier.sh"
mkdir -p "$SPOOL"

# Stands in for notifier.sh: records argv and any stdin payload.
cat > "$STUB" <<'STUB_EOF'
#!/bin/bash
payload=""
[[ ! -t 0 ]] && payload="$(cat)"
printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$payload" >> "$LOGFILE"
STUB_EOF
chmod +x "$STUB"

spool_event() {
    local seq="$1" event="$2" cwd="$3" tool="${4:-}"
    printf '%s\t%s\t%s\n' "$event" "$cwd" "$tool" > "$SPOOL/1700000000000-$seq.tmp"
    mv "$SPOOL/1700000000000-$seq.tmp" "$SPOOL/1700000000000-$seq.ev"
}

wait_for_lines() {
    local expected="$1"
    for _ in $(seq 1 60); do
        [[ -f "$LOG" ]] && [[ $(wc -l < "$LOG") -ge "$expected" ]] && return 0
        sleep 0.1
    done
    return 1
}

# A directory that is not a git repository, so the project name is its basename
# and the assertions do not depend on where the tests are checked out.
PROJECT_DIR="$TEST_ROOT/my-project"
mkdir -p "$PROJECT_DIR"

# The relay always starts in the directory the launcher mounted, and it uses
# that as the boundary for the container-supplied cwd — so every relay here is
# started from PROJECT_DIR, as the real launcher would.
start_relay() {
    LOGFILE="$LOG" \
    CODE_NOTIFY_NOTIFIER_PATH="$STUB" \
    CODE_NOTIFY_RELAY_SESSION_PID="${RELAY_SESSION_PID_OVERRIDE:-$$}" \
    CODE_NOTIFY_RELAY_POLL_SECONDS="${RELAY_POLL_OVERRIDE:-0.05}" \
        bash -c "cd \"\$1\" && exec bash \"\$2\" relay omp \"\$3\"" \
            _ "$PROJECT_DIR" "$CLI" "$SPOOL" 2>/dev/null &
    RELAY_PID=$!
}

spool_event 0000 prompt_submit "$PROJECT_DIR"
spool_event 0001 permission_request "$PROJECT_DIR" bash
spool_event 0002 question_asked "$PROJECT_DIR" ask
spool_event 0003 permission_replied "$PROJECT_DIR"
spool_event 0004 stop "$PROJECT_DIR"
spool_event 0005 stop_failure "$PROJECT_DIR"

start_relay

wait_for_lines 6 || fail "relay did not dispatch all six events (got: $(cat "$LOG" 2>/dev/null))"

expect_line() {
    local expected="$1" label="$2"
    grep -Fqx "$expected" "$LOG" || fail "$label — expected '$expected' in: $(cat "$LOG")"
    pass "$label"
}

expect_line "UserPromptSubmit|omp|my-project|" "prompt_submit maps to UserPromptSubmit"
expect_line "notification|omp|my-project|{\"type\":\"permission_prompt\"}" "permission_request carries the permission_prompt payload"
expect_line "notification|omp|my-project|{\"type\":\"elicitation_dialog\"}" "question_asked carries the elicitation_dialog payload"
expect_line "ResumeAfterInput|omp|my-project|" "permission_replied maps to ResumeAfterInput"
expect_line "stop|omp|my-project|" "stop maps to the stop hook"
expect_line "StopFailure|omp|my-project|" "stop_failure maps to StopFailure"

# Ordering is the meaning: the notifier's running → paused → resumed state
# machine is driven by the sequence, not by the events alone.
if [[ "$(head -n1 "$LOG")" != "UserPromptSubmit|omp|my-project|" ]]; then
    fail "events were not dispatched in filename order: $(cat "$LOG")"
fi
pass "events dispatch in spool order"

# An unknown event (newer hook, older relay) and a record trying to smuggle a
# command must both produce nothing at all. session_end joins them: it is the
# silent teardown an exit or an interrupt takes, so it must reach the notifier
# no more than they do. (No turn is in flight here, so the teardown itself
# returns before touching tmux.)
BEFORE="$(wc -l < "$LOG")"
spool_event 0006 future_event "$PROJECT_DIR"
spool_event 0007 'stop; touch /tmp/code-notify-relay-pwned' "$PROJECT_DIR"
spool_event 0008 session_end "$PROJECT_DIR"
sleep 0.6

if [[ "$(wc -l < "$LOG")" -ne "$BEFORE" ]]; then
    fail "an unknown, malformed or silent event was dispatched: $(cat "$LOG")"
fi
pass "unknown, malformed and silent events reach no notifier"

if [[ -e /tmp/code-notify-relay-pwned ]]; then
    rm -f /tmp/code-notify-relay-pwned
    fail "a spool record was executed as a command"
fi
pass "spool records are never executed"

# Consumed files are removed, so a notifier that hangs cannot cause a replay.
if compgen -G "$SPOOL/*.ev" > /dev/null; then
    fail "spool files remained after dispatch: $(ls "$SPOOL")"
fi
pass "consumed spool files are removed"

# The relay's lifetime is the launcher's: losing the spool ends it.
rm -rf "$SPOOL"
for _ in $(seq 1 40); do
    kill -0 "$RELAY_PID" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$RELAY_PID" 2>/dev/null; then
    fail "relay kept running after its spool directory disappeared"
fi
RELAY_PID=""
pass "relay exits when the spool directory disappears"

# The container writes the turn's completion milliseconds before it exits, and
# the launcher kills the relay as soon as `docker run` returns. If SIGTERM ended
# the relay where it landed, that final stop — the notification the user was
# actually waiting for — would be dropped.
mkdir -p "$SPOOL"
: > "$LOG"
start_relay

# Let the relay install its signal handler; before that, SIGTERM is simply
# fatal, which is the shell's behaviour and not what this asserts.
sleep 0.5

spool_event 0100 stop "$PROJECT_DIR"
kill "$RELAY_PID" 2>/dev/null
wait "$RELAY_PID" 2>/dev/null || true
RELAY_PID=""

grep -Fqx "stop|omp|my-project|" "$LOG" || fail "a stop written just before SIGTERM was dropped: $(cat "$LOG")"
pass "events written just before shutdown are still delivered"

# The poll interval is validated, not trusted. `sleep` rejecting its argument
# returns immediately, and the loop tolerates sleep failures so the launcher's
# SIGTERM does not look like an error — so an unusable value would spin a core
# for the whole session instead of raising anything.
effective_interval() {
    (
        CODE_NOTIFY_RELAY_POLL_SECONDS="$1"
        export CODE_NOTIFY_RELAY_POLL_SECONDS
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/../lib/code-notify/utils/container-relay.sh" 2>/dev/null
        printf '%s' "$CONTAINER_RELAY_POLL_SECONDS"
    )
}

check_interval() {
    local input="$1" expected="$2" label="$3" actual
    actual="$(effective_interval "$input")"
    [[ "$actual" == "$expected" ]] || fail "$label — '$input' produced '$actual', expected '$expected'"
    pass "$label"
}

check_interval "0.05" "0.05" "a valid sub-second interval is honoured"
check_interval "2" "2" "a valid whole-second interval is honoured"
check_interval "0" "0.2" "zero falls back to the default instead of spinning"
check_interval "0.0" "0.2" "a zero fraction falls back to the default"
check_interval "abc" "0.2" "a non-numeric value falls back to the default"
check_interval "-1" "0.2" "a negative value falls back to the default"
check_interval "" "0.2" "an unset value uses the default"

# The behaviour that matters, not just the parsed value: a relay started with
# an unusable interval must idle, not burn a core.
mkdir -p "$SPOOL"
: > "$LOG"
RELAY_POLL_OVERRIDE=0 start_relay

sleep 2
RELAY_CPU="$(ps -o %cpu= -p "$RELAY_PID" 2>/dev/null | tr -d ' ')"
kill "$RELAY_PID" 2>/dev/null
wait "$RELAY_PID" 2>/dev/null || true
RELAY_PID=""

[[ -n "$RELAY_CPU" ]] || fail "the relay exited early with an invalid poll interval"
# Measured: ~0.3% throttled, ~17% unthrottled (the loop still forks `sleep`
# every iteration, so it does not reach a full core — which is exactly why the
# threshold has to sit near the floor rather than near 100%). 5% keeps ~16x
# headroom over the throttled case while still failing the runaway one.
if [[ "${RELAY_CPU%%.*}" -ge 5 ]]; then
    fail "an invalid poll interval left the relay spinning (${RELAY_CPU}% CPU)"
fi
pass "an invalid poll interval does not leave the relay spinning (${RELAY_CPU}% CPU)"

# The watched launcher PID is validated for the same reason, and both ways of
# being wrong fail silently in opposite directions: a non-numeric value makes
# `kill -0` fail, which reads as "the launcher exited" and stops the relay on
# its first tick; zero makes `kill -0 0` address the caller's whole process
# group, which never fails, so the relay outlives its session.
effective_session_pid() {
    (
        CODE_NOTIFY_RELAY_SESSION_PID="$1"
        export CODE_NOTIFY_RELAY_SESSION_PID
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/../lib/code-notify/utils/container-relay.sh" 2>/dev/null
        printf '%s' "$CONTAINER_RELAY_SESSION_PID"
    )
}

check_session_pid() {
    local input="$1" label="$2" actual
    actual="$(effective_session_pid "$input")"
    [[ "$actual" =~ ^[1-9][0-9]*$ ]] \
        || fail "$label — '$input' produced '$actual', which is not a usable PID"
    if [[ -n "$input" ]] && [[ "$input" =~ ^[1-9][0-9]*$ ]]; then
        [[ "$actual" == "$input" ]] || fail "$label — a valid PID was not honoured"
    else
        [[ "$actual" != "$input" ]] || fail "$label — an invalid PID was passed through"
    fi
    pass "$label"
}

check_session_pid "$$" "a valid launcher PID is honoured"
check_session_pid "0" "zero is rejected rather than addressing the process group"
check_session_pid "abc" "a non-numeric PID is rejected"
check_session_pid "-1" "a negative PID is rejected"
check_session_pid "" "an unset PID falls back to the real parent"

# Behaviour, not just the parsed value: with a garbage PID the relay must keep
# working, rather than reading the failed `kill -0` as "my launcher exited".
mkdir -p "$SPOOL"
: > "$LOG"
RELAY_SESSION_PID_OVERRIDE="not-a-pid" start_relay

sleep 0.6
spool_event 0200 stop "$PROJECT_DIR"
wait_for_lines 1 || fail "the relay exited on startup because of an invalid session PID"
grep -Fqx "stop|omp|my-project|" "$LOG" \
    || fail "an event was not delivered with an invalid session PID: $(cat "$LOG")"
kill "$RELAY_PID" 2>/dev/null
wait "$RELAY_PID" 2>/dev/null || true
RELAY_PID=""
pass "an invalid session PID does not silently kill the relay"

# The record's working directory is named by the container, where the agent can
# write spool files — so a forged record must never steer the host-side `git -C`
# into a directory of the agent's choosing. The relay ignores the value and uses
# its own; these cases exist so that re-introducing any form of "trust it, but
# check the prefix" fails here. A prefix check passes all three: a sibling path,
# a traversal through the launch directory, and a symlink planted inside it (the
# mount is writable, so the agent can create one).
OUTSIDE="$TEST_ROOT/outside-the-mount"
mkdir -p "$OUTSIDE"
ln -sfn "$OUTSIDE" "$PROJECT_DIR/escape-link"

check_untrusted_cwd() {
    local cwd="$1" seq="$2" label="$3"

    mkdir -p "$SPOOL"
    : > "$LOG"
    start_relay
    sleep 0.5
    spool_event "$seq" stop "$cwd"
    wait_for_lines 1 || fail "$label — no event was dispatched at all"
    kill "$RELAY_PID" 2>/dev/null
    wait "$RELAY_PID" 2>/dev/null || true
    RELAY_PID=""

    if grep -Fq "outside-the-mount" "$LOG"; then
        fail "$label — the record's directory was used: $(cat "$LOG")"
    fi
    grep -Fqx "stop|omp|my-project|" "$LOG" \
        || fail "$label — the relay's own project name was not used: $(cat "$LOG")"
    pass "$label"
}

check_untrusted_cwd "$OUTSIDE" 0300 \
    "a directory outside the launch tree is not used"
check_untrusted_cwd "$PROJECT_DIR/../outside-the-mount" 0301 \
    "a traversal back out of the launch tree is not used"
check_untrusted_cwd "$PROJECT_DIR/escape-link" 0302 \
    "a symlink planted inside the launch tree is not followed"

echo "All container relay tests passed"
