#!/bin/bash

# opencode plugin behaviour: which notifier invocation each opencode event
# produces. Runs the real plugin under bun (opencode's own runtime) against a
# fake notifier that records argv and stdin.
#
# The failures this guards against, worst first:
#   - an approval or question prompt that produces no notification: the user
#     is left waiting on a dialog nobody told them about;
#   - a subagent's turn end announced as the user's task completion, or the
#     same turn end announced twice because opencode emits both session.idle
#     and session.status(idle);
#   - a turn the user interrupted announced as a completed task.
#
# Skipped when bun is absent (CI installs it; a bare checkout may not have it).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
LIB_DIR="$ROOT_DIR/lib/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

if ! command -v bun &> /dev/null; then
    echo "SKIP: bun not installed (opencode's plugin runtime)"
    exit 0
fi

test_dir="$(mktemp -d)"
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

log_file="$test_dir/notifier-calls.log"

# Fake notifier: one line per run, "<hook>|<tool>|<stdin>".
cat > "$test_dir/notifier.sh" <<'EOF'
#!/bin/bash
payload=""
if [[ ! -t 0 ]]; then
    payload=$(cat 2>/dev/null || true)
fi
printf '%s|%s|%s\n' "${1:-}" "${2:-}" "$payload" >> "$FAKE_NOTIFIER_LOG"
EOF
chmod +x "$test_dir/notifier.sh"

# Render through the real installer, with only the notifier path redirected to
# the fake — so this exercises the shipped renderer, not a copy of it.
(
    # shellcheck source=/dev/null
    source "$LIB_DIR/utils/colors.sh"
    # shellcheck source=/dev/null
    source "$LIB_DIR/utils/detect.sh"
    # shellcheck source=/dev/null
    source "$LIB_DIR/core/config.sh"
    get_notify_script() { printf '%s\n' "$test_dir/notifier.sh"; }
    render_opencode_plugin > "$test_dir/plugin.ts"
) || fail "rendering the plugin failed"

# Driver: loads the plugin and replays a scripted event sequence. Each case is
# a separate driver run, so one case's session state cannot mask another's.
cat > "$test_dir/drive.ts" <<'EOF'
import { CodeNotify } from "./plugin.ts"

const script = JSON.parse(process.argv[2])
const hooks: any = await CodeNotify({ directory: process.cwd() })

for (const step of script) {
	if (step.hook === "chat.message") await hooks["chat.message"]?.(step.input)
	else await hooks.event?.({ event: step })
}

// The notifier runs are detached children; give them a moment to be exec'd
// and to write their line before the assertions read the log.
await new Promise((resolve) => setTimeout(resolve, 700))
EOF

# Wait for the log to stop growing. The driver's own delay covers the common
# case, but the notifier runs are detached children racing this shell, and a
# loaded machine can exec them late — which would fail an assertion for a
# notification that was merely slow, not missing.
settle_log() {
    local previous="" current="" stable=0 i
    for ((i = 0; i < 60; i++)); do
        current="$(wc -c < "$log_file" 2>/dev/null || printf 0)"
        if [[ "$current" == "$previous" ]]; then
            stable=$((stable + 1))
            (( stable >= 2 )) && return 0
        else
            stable=0
        fi
        previous="$current"
        sleep 0.1
    done
    return 0
}

drive() {
    : > "$log_file"
    (
        export FAKE_NOTIFIER_LOG="$log_file"
        builtin cd "$test_dir"
        bun run "$test_dir/drive.ts" "$1" > /dev/null 2>&1
    ) || fail "driver run failed for: $1"
    settle_log
}

# Sorted, because the notifier runs are independent detached processes: they
# append in whatever order they get scheduled, not the order they were spawned.
# Comparing the raw sequence would fail whenever two of them inverted.
hooks_seen() {
    cut -d'|' -f1 < "$log_file" | LC_ALL=C sort | tr '\n' ','
}

MAIN='{"type":"session.created","properties":{"info":{"id":"ses_main"}}}'
CHILD='{"type":"session.created","properties":{"info":{"id":"ses_kid","parentID":"ses_main"}}}'
PROMPT='{"hook":"chat.message","input":{"sessionID":"ses_main"}}'

# --- a plain turn: one prompt in, exactly one completion out ---------------
drive "[$MAIN,$PROMPT,{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_main\"}}]"
[[ "$(hooks_seen)" == "UserPromptSubmit,stop," ]] ||
    fail "a plain turn produced: $(hooks_seen)"
pass "a turn submits and completes exactly once"

# --- opencode emits both idle events; only one completion may result -------
drive "[$MAIN,$PROMPT,{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_main\"}},{\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_main\",\"status\":{\"type\":\"idle\"}}}]"
[[ "$(grep -c '^stop|' "$log_file")" -eq 1 ]] ||
    fail "session.idle plus session.status(idle) produced $(grep -c '^stop|' "$log_file") completions"
pass "the two turn-end events collapse into one completion"

# --- a subagent's turn end is not the user's -------------------------------
drive "[$MAIN,$CHILD,$PROMPT,{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_kid\"}}]"
grep -q '^stop|' "$log_file" &&
    fail "a subagent turn end was announced as a task completion"
pass "subagent turn ends are not announced"

# --- but a subagent's approval prompt is ----------------------------------
drive "[$MAIN,$CHILD,{\"type\":\"permission.asked\",\"properties\":{\"sessionID\":\"ses_kid\",\"id\":\"per_1\"}}]"
grep -q '^notification|opencode|{"type":"permission_prompt"}$' "$log_file" ||
    fail "a subagent approval prompt did not notify: $(cat "$log_file")"
pass "approval prompts notify, including a subagent's"

# --- a subagent aborting must not touch the parent's turn -----------------
# SessionEnd carries no session id: it tears down whatever pane the process is
# in. Sent for a subagent while the user's own turn is still running, it takes
# down that turn's running indicator.
drive "[$MAIN,$CHILD,$PROMPT,{\"type\":\"session.error\",\"properties\":{\"sessionID\":\"ses_kid\",\"error\":{\"name\":\"MessageAbortedError\"}}}]"
grep -q '^SessionEnd|' "$log_file" &&
    fail "a subagent abort tore down the running turn: $(cat "$log_file")"
pass "a subagent abort leaves the parent turn alone"

# --- nor may a subagent's failure be reported as the turn's ---------------
drive "[$MAIN,$CHILD,$PROMPT,{\"type\":\"session.error\",\"properties\":{\"sessionID\":\"ses_kid\",\"error\":{\"name\":\"APIError\"}}}]"
grep -q '^StopFailure|' "$log_file" &&
    fail "a subagent error raised a failure alert for the user's turn: $(cat "$log_file")"
pass "a subagent error does not alert on the parent turn"

# --- an error with no session cannot be attributed to one -----------------
drive "[$MAIN,$PROMPT,{\"type\":\"session.error\",\"properties\":{\"error\":{\"name\":\"APIError\"}}}]"
[[ "$(hooks_seen)" == "UserPromptSubmit," ]] ||
    fail "a session-less error acted on some turn: $(hooks_seen)"
pass "a session-less error is ignored"

# --- versioned prompt events still notify, and only once ------------------
drive "[$MAIN,{\"type\":\"permission.v2.asked\",\"properties\":{\"sessionID\":\"ses_main\",\"id\":\"per_9\"}}]"
grep -q '^notification|opencode|{"type":"permission_prompt"}$' "$log_file" ||
    fail "permission.v2.asked did not notify: $(cat "$log_file")"
pass "versioned permission events notify"

drive "[$MAIN,{\"type\":\"permission.asked\",\"properties\":{\"sessionID\":\"ses_main\",\"id\":\"per_9\"}},{\"type\":\"permission.v2.asked\",\"properties\":{\"sessionID\":\"ses_main\",\"id\":\"per_9\"}}]"
[[ "$(grep -c '^notification|' "$log_file")" -eq 1 ]] ||
    fail "one request announced under both spellings toasted $(grep -c '^notification|' "$log_file") times"
pass "an event and its versioned alias toast once"

# --- the older SDK event name still notifies ------------------------------
drive "[{\"type\":\"permission.updated\",\"properties\":{\"sessionID\":\"ses_main\",\"id\":\"per_1\"}}]"
grep -q '^notification|opencode|{"type":"permission_prompt"}$' "$log_file" ||
    fail "permission.updated (older opencode) did not notify"
pass "both permission event names notify"

# --- a question is an input request too -----------------------------------
drive "[$MAIN,{\"type\":\"question.asked\",\"properties\":{\"sessionID\":\"ses_main\",\"id\":\"que_1\"}}]"
grep -q '^notification|opencode|{"type":"elicitation_dialog"}$' "$log_file" ||
    fail "a question prompt did not notify: $(cat "$log_file")"
pass "question prompts notify"

# --- answering one puts the running indicator back ------------------------
drive "[$MAIN,{\"type\":\"permission.replied\",\"properties\":{\"sessionID\":\"ses_main\",\"requestID\":\"per_1\",\"reply\":\"once\"}}]"
[[ "$(hooks_seen)" == "ResumeAfterInput," ]] ||
    fail "a permission reply produced: $(hooks_seen)"
pass "answering a prompt resumes the running indicator"

# --- an interrupted turn is torn down, not announced ----------------------
drive "[$MAIN,$PROMPT,{\"type\":\"session.error\",\"properties\":{\"sessionID\":\"ses_main\",\"error\":{\"name\":\"MessageAbortedError\"}}},{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_main\"}}]"
grep -q '^stop|' "$log_file" &&
    fail "an interrupted turn was announced as complete: $(cat "$log_file")"
grep -q '^SessionEnd|opencode|' "$log_file" ||
    fail "an interrupted turn did not tear the running indicator down: $(cat "$log_file")"
pass "an interrupted turn tears down silently"

# --- a failed turn raises a failure alert carrying the error class --------
drive "[$MAIN,$PROMPT,{\"type\":\"session.error\",\"properties\":{\"sessionID\":\"ses_main\",\"error\":{\"name\":\"APIError\"}}}]"
grep -q '^StopFailure|opencode|{"error":"APIError"}$' "$log_file" ||
    fail "a session error did not raise a failure alert: $(cat "$log_file")"
pass "session errors raise a failure alert"

# --- a turn that began before the plugin loaded still completes -----------
drive "[{\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_late\",\"status\":{\"type\":\"busy\"}}},{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_late\"}}]"
grep -q '^stop|' "$log_file" ||
    fail "a turn known only from session.status(busy) never completed"
pass "a turn seen only as busy still completes"

# --- an unrendered plugin does nothing at all -----------------------------
: > "$log_file"
/bin/cp "$LIB_DIR/hooks/opencode/code-notify.ts" "$test_dir/plugin.ts"
(
    export FAKE_NOTIFIER_LOG="$log_file"
    builtin cd "$test_dir"
    bun run "$test_dir/drive.ts" "[$MAIN,$PROMPT,{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_main\"}}]" > /dev/null 2>&1
) || fail "the unrendered plugin threw instead of disabling itself"
[[ ! -s "$log_file" ]] || fail "an unrendered plugin invoked something: $(cat "$log_file")"
pass "an unrendered plugin disables itself"

# ---------------------------------------------------------------------------
# The rendered notifier path round-trips through TypeScript's string rules.
#
# The install escapes the path for a TS literal and then splices it in. Both
# halves have to agree, and nothing short of running the result proves they do:
# a mis-rendered path produces a plugin that loads fine and silently spawns
# nothing. So put the notifier at a path carrying every character that means
# something to a substitution engine or to a TS string, and require that exact
# file to run.
# ---------------------------------------------------------------------------
hostile_dir="$test_dir/amp & back\\slash \"quote\""
mkdir -p "$hostile_dir"
hostile_notifier="$hostile_dir/notifier.sh"
/bin/cp "$test_dir/notifier.sh" "$hostile_notifier"

(
    # shellcheck source=/dev/null
    source "$LIB_DIR/utils/colors.sh"
    # shellcheck source=/dev/null
    source "$LIB_DIR/utils/detect.sh"
    # shellcheck source=/dev/null
    source "$LIB_DIR/core/config.sh"
    get_notify_script() { printf '%s\n' "$hostile_notifier"; }
    render_opencode_plugin > "$test_dir/plugin.ts"
) || fail "rendering to a hostile path failed"

drive "[$MAIN,$PROMPT,{\"type\":\"session.idle\",\"properties\":{\"sessionID\":\"ses_main\"}}]"
[[ "$(hooks_seen)" == "UserPromptSubmit,stop," ]] ||
    fail "a notifier at a path with & \\ and \" was not run: $(hooks_seen)"
pass "the rendered notifier path survives &, backslash and quote"

echo "All opencode event tests passed"
