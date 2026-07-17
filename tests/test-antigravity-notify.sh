#!/bin/bash

# Antigravity CLI (agy) notification mapping tests.
#
# agy passes no argv to a hook and delivers a JSON payload on stdin; code-notify
# wraps each lifecycle event as "agy:<Event>" + "antigravity". This exercises the
# notifier's antigravity branch directly (no agy binary required):
#   * PreToolUse           -> "Input Required" (permission prompt)
#   * PreInvocation        -> silent: running indicator + debounce cancel
#   * PostToolUse + error  -> "Error" (string OR structured HookErrorMessage)
#   * PostToolUse, no error -> debounced "Task Complete" (via the watcher),
#                              skipped once a native Stop was seen (agy 1.1.3+)
#   * Stop                 -> "Task Complete", or "Error" when the payload
#                              carries the turn's terminal error
# Project name comes from workspacePaths[0].

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="$SCRIPT_DIR/../lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

wait_for_lines() {
    local file="$1"
    local expected_lines="$2"

    for _ in $(seq 1 60); do
        if [[ -f "$file" ]] && [[ $(wc -l < "$file") -ge "$expected_lines" ]]; then
            return 0
        fi
        sleep 0.1
    done

    return 1
}

# Project extraction relies on jq or python3; skip cleanly if neither exists.
if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: jq or python3 required for Antigravity notify test"
    exit 0
fi

run_agy_notifier() {
    local fake_path="$1"
    local event="$2"
    local payload="$3"
    local hook_type="${4:-}"

    printf '%s' "$payload" \
    | PATH="$fake_path" \
      CLAUDE_HOOK_TYPE="$hook_type" \
      CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
      CODE_NOTIFY_AGY_DEBOUNCE_SECONDS=1 \
      CODE_NOTIFY_TAIL_SYNC=1 \
      bash "$NOTIFIER" "agy:$event" "antigravity"
}

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
log_dir="$test_dir/log"
mkdir -p "$HOME/.claude/notifications" "$HOME/.claude/logs" "$fake_bin" "$log_dir"

# The run_command approval banner is gated on the permission_prompt alert type
# at runtime (the notifier reads this file directly). Enable it so the PreToolUse
# approval scenarios below deliver a banner.
printf '%s' "idle_prompt|permission_prompt" > "$HOME/.claude/notifications/notify-types"

case "$(uname -s)" in
    Darwin)
        notification_log="$log_dir/terminal-notifier.log"
        cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "-help" ]]; then exit 0; fi
printf '%s\n' "\$*" >> "$notification_log"
EOF
        ;;
    Linux)
        notification_log="$log_dir/notify-send.log"
        cat > "$fake_bin/notify-send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$notification_log"
EOF
        ;;
    *)
        echo "SKIP: unsupported OS for Antigravity notify test"
        exit 0
        ;;
esac

chmod +x "$fake_bin"/*

fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

fake_tmux_dir="$test_dir/tmux"
mkdir -p "$fake_tmux_dir"
cat > "$fake_bin/tmux" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_TMUX_LOG"
args=("$@")
if [[ "${args[0]}" == "-S" ]]; then
    args=("${args[@]:2}")
fi
cmd="${args[0]}"
args=("${args[@]:1}")
target=""
fmt=""
unset_opt=0
rest=()
while (( ${#args[@]} )); do
    a="${args[0]}"
    case "$a" in
        -t) target="${args[1]}"; args=("${args[@]:2}") ;;
        -F) fmt="${args[1]}"; args=("${args[@]:2}") ;;
        -*) [[ "$a" == -*u* ]] && unset_opt=1; args=("${args[@]:1}") ;;
        *) rest+=("$a"); args=("${args[@]:1}") ;;
    esac
done
case "$cmd" in
    display-message)
        case "${rest[0]}" in
            '#{session_id} #{window_id} #{pane_id}') printf '%s\n' '$1 @2 %3' ;;
            *'#{window_id}|#{automatic-rename}|#{&&:#{window_active},#{session_attached}}|#{window_name}'*)
                printf '%s\n' "@2|on|${FAKE_TMUX_VISIBLE:-1}|$(cat "$FAKE_TMUX_STATE/@2.window_name")"
                ;;
            '#{window_name}') cat "$FAKE_TMUX_STATE/${target}.window_name" 2>/dev/null; echo ;;
            *) printf '%s\n' "$FAKE_TMUX_TARGET" ;;
        esac
        ;;
    list-windows)
        if [[ "$fmt" == *window_active* ]]; then
            mode=$(cat "$FAKE_TMUX_STATE/@2.@code_notify_clear_mode" 2>/dev/null)
            orig=$(cat "$FAKE_TMUX_STATE/@2.@code_notify_orig_name" 2>/dev/null)
            printf '%s\n' "@2|${FAKE_TMUX_VISIBLE:-1}|$mode|$orig"
        elif [[ -f "$FAKE_TMUX_STATE/@2.@code_notify_running" ]]; then
            since=$(cat "$FAKE_TMUX_STATE/@2.@code_notify_running")
            mode=$(cat "$FAKE_TMUX_STATE/@2.@code_notify_clear_mode" 2>/dev/null)
            printf '%s\n' "@2|$since|$mode"
        fi
        ;;
    show-options)
        cat "$FAKE_TMUX_STATE/${target}.${rest[0]}" 2>/dev/null
        ;;
    set-option)
        if (( unset_opt )); then
            rm -f "$FAKE_TMUX_STATE/${target}.${rest[0]}"
        else
            printf '%s' "${rest[1]}" > "$FAKE_TMUX_STATE/${target}.${rest[0]}"
        fi
        ;;
    rename-window)
        printf '%s' "${rest[0]}" > "$FAKE_TMUX_STATE/${target}.window_name"
        ;;
    set-hook)
        printf '%s\n' "$*" >> "$FAKE_TMUX_HOOK_LOG"
        ;;
esac
exit 0
EOF
chmod +x "$fake_bin/tmux"
export FAKE_TMUX_LOG="$fake_tmux_dir/calls.log"
export FAKE_TMUX_HOOK_LOG="$fake_tmux_dir/hooks.log"
export FAKE_TMUX_STATE="$fake_tmux_dir/state"
mkdir -p "$FAKE_TMUX_STATE"
: > "$FAKE_TMUX_HOOK_LOG"
export TMUX="$test_dir/sock,12345,0"
export TMUX_PANE="%3"
export FAKE_TMUX_TARGET='$1 @2 %3'
export FAKE_TMUX_VISIBLE=1
printf '%s' "zsh" > "$FAKE_TMUX_STATE/@2.window_name"

ws() { printf '"workspacePaths":["/tmp/work/%s"]' "$1"; }

# Match the user's Antigravity permission configuration: git commands are
# auto-approved and therefore must not produce an "Input Required" banner.
mkdir -p "$HOME/.gemini/antigravity-cli"
cat > "$HOME/.gemini/antigravity-cli/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["command(git)"]
  }
}
EOF

# 1) PreToolUse while agy waits for approval -> Input Required.
run_agy_notifier "$fake_path" "PreToolUse" \
    "{\"conversationId\":\"c-pre\",\"toolCall\":{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"echo hi\"}},$(ws projInput)}"

# 1b) A git command covered by permissions.allow auto-runs and must be silent.
# Antigravity 1.1.1 wraps the model-provided CommandLine in an extra pair of
# quotes in the hook payload, while stripping them for permission evaluation.
run_agy_notifier "$fake_path" "PreToolUse" \
    "{\"conversationId\":\"c-allowed\",\"toolCall\":{\"name\":\"run_command\",\"args\":{\"CommandLine\":\"\\\"git diff\\\"\"}},$(ws projAllowed)}"

# 2) PostToolUse with a STRUCTURED error -> Error (must not be read as success).
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-err\",\"error\":{\"message\":\"build blew up\",\"code\":1},$(ws projErr)}"

# 3) PostToolUse with empty error -> debounced Task Complete (fires from watcher).
# Antigravity exports this compatibility variable to hook commands. It must not
# divert the agy wrapper into the Claude/Codex PostToolUse fast path.
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-done\",\"error\":\"\",$(ws projDone)}" "PostToolUse"

# 4) Native Stop event -> Task Complete (dormant in agy today, but mapped).
run_agy_notifier "$fake_path" "Stop" \
    "{\"conversationId\":\"c-stop\",$(ws projStop)}"

# 5) A successful step that arms the debounce, immediately followed by an error
#    in the same conversation: the error must cancel the pending completion, so
#    we expect an Error and NO Task Complete for projCancel.
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-cancel\",\"error\":\"\",$(ws projCancel)}"
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-cancel\",\"error\":{\"message\":\"late failure\"},$(ws projCancel)}"

# 6) A successful step arms the debounce, then a PreToolUse (waiting for
#    approval) arrives in the same conversation: the agent is not done, so the
#    PreToolUse must cancel the pending completion. Expect Input Required and
#    NO Task Complete for projApprove.
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-approve\",\"error\":\"\",$(ws projApprove)}"
run_agy_notifier "$fake_path" "PreToolUse" \
    "{\"conversationId\":\"c-approve\",\"toolCall\":{\"name\":\"run_command\"},$(ws projApprove)}"

# 6b) The core fix: a successful step arms the debounce, then a NON-run_command
#     tool starts (PreToolUse for a slow read) in the same conversation. The
#     agent is still working, so the PreToolUse must cancel the pending
#     completion — and produce NO banner of its own (only run_command prompts).
#     Without this, a tool outliving the debounce window fires a bogus complete.
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-busy\",\"error\":\"\",$(ws projBusy)}"
run_agy_notifier "$fake_path" "PreToolUse" \
    "{\"conversationId\":\"c-busy\",\"toolCall\":{\"name\":\"read_file\"},$(ws projBusy)}"

# Five fire synchronously (projInput, projErr, projStop, projCancel error,
# projApprove input); the debounced projDone complete arrives ~1s later -> six.
# projBusy must produce nothing (silent cancel).
wait_for_lines "$notification_log" 6 || fail "expected six Antigravity notification deliveries"
# Give any (incorrectly) pending debounce watchers time to fire before asserting.
sleep 2

grep -q "Input Required - projInput" "$notification_log" \
    || fail "PreToolUse did not map to an input-required notification"
grep -q "Error - projErr" "$notification_log" \
    || fail "structured PostToolUse error was not classified as a failure"
grep -q "Task Complete - projDone" "$notification_log" \
    || fail "debounced PostToolUse did not produce a task-complete notification"
grep -q "Task Complete - projStop" "$notification_log" \
    || fail "Stop event did not map to a task-complete notification"
grep -q "Error - projCancel" "$notification_log" \
    || fail "late error in the cancel scenario was not reported"
grep -q "Input Required - projApprove" "$notification_log" \
    || fail "PreToolUse in the approval scenario was not reported"
grep -q "projAllowed" "$notification_log" \
    && fail "allowlisted git command emitted an input-required notification"

# A PostToolUse error must NOT also be reported as complete for the same project.
grep -q "Task Complete - projErr" "$notification_log" \
    && fail "error payload was incorrectly reported as task complete"
# The error must have cancelled the earlier debounced completion.
grep -q "Task Complete - projCancel" "$notification_log" \
    && fail "error did not cancel the pending debounced completion"
# A PreToolUse (waiting for approval) must cancel the pending completion.
grep -q "Task Complete - projApprove" "$notification_log" \
    && fail "PreToolUse did not cancel the pending debounced completion"
# A non-run_command tool start must cancel the pending completion (the core fix).
grep -q "Task Complete - projBusy" "$notification_log" \
    && fail "non-run_command PreToolUse did not cancel the pending debounced completion"
# ...and it must stay silent (no approval banner for non-run_command tools).
grep -q "projBusy" "$notification_log" \
    && fail "non-run_command PreToolUse emitted a notification (should be silent)"

# 6c) Antigravity uses engage-clear badge state. A real focus sweep must leave
#     both completion and idle badges in place.
before_hook_lines="$(wc -l < "$FAKE_TMUX_HOOK_LOG")"
run_agy_notifier "$fake_path" "Stop" \
    "{\"conversationId\":\"c-focus\",\"error\":\"\",$(ws projFocus)}"
[[ "$(cat "$FAKE_TMUX_STATE/@2.@code_notify_clear_mode")" == "engage" ]] \
    || fail "Antigravity completion badge should use engage-clear mode"
after_hook_lines="$(wc -l < "$FAKE_TMUX_HOOK_LOG")"
[[ "$after_hook_lines" -eq "$before_hook_lines" ]] \
    || fail "Antigravity completion badge should not arm the focus-clear hook"
bash "$SCRIPT_DIR/../lib/code-notify/utils/tmux.sh" badge-sweep
[[ "$(cat "$FAKE_TMUX_STATE/@2.window_name")" == "🟢 zsh" ]] \
    || fail "Antigravity completion badge should remain after a focus sweep"

export FAKE_TMUX_VISIBLE=0
printf '%s' '{"type":"idle_prompt"}' \
    | PATH="$fake_path" CODE_NOTIFY_TAIL_SYNC=1 \
      bash "$NOTIFIER" notification antigravity projFocus
[[ "$(cat "$FAKE_TMUX_STATE/@2.window_name")" == "🥱 zsh" ]] \
    || fail "Antigravity idle prompt should replace the completion badge"
export FAKE_TMUX_VISIBLE=1
bash "$SCRIPT_DIR/../lib/code-notify/utils/tmux.sh" badge-sweep
[[ "$(cat "$FAKE_TMUX_STATE/@2.window_name")" == "🥱 zsh" ]] \
    || fail "Antigravity idle prompt badge should remain after a focus sweep"

# 7) Regression (P1): error alerts must honour the kill switch (cn off). With the
#    disabled marker present, a PostToolUse error must NOT be delivered.
lines_before="$(wc -l < "$notification_log")"
touch "$HOME/.claude/notifications/disabled"
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-killed\",\"error\":{\"message\":\"should be silenced\"},$(ws projKilled)}"
rm -f "$HOME/.claude/notifications/disabled"
grep -q "projKilled" "$notification_log" \
    && fail "error alert bypassed the kill switch (cn off)"
[[ "$(wc -l < "$notification_log")" == "$lines_before" ]] \
    || fail "an alert was delivered while notifications were disabled"

# 8) Regression (P2): a native Stop must cancel the pending PostToolUse debounce
#    so completion fires once, not twice. Arm the debounce, then send Stop in the
#    same conversation and wait out the debounce window for any second delivery.
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-stoponce\",\"error\":\"\",$(ws projStopOnce)}"
run_agy_notifier "$fake_path" "Stop" \
    "{\"conversationId\":\"c-stoponce\",$(ws projStopOnce)}"
sleep 2
stop_once_count="$(grep -c "Task Complete - projStopOnce" "$notification_log")"
[[ "$stop_once_count" == "1" ]] \
    || fail "native Stop produced $stop_once_count completion alerts (expected 1)"

# 8b) PreInvocation (fires before every model call since agy 1.1.3) must light
#     the running indicator, cancel a pending debounced completion, and stay
#     silent — it is agy's prompt-submit signal, not a notification.
rm -f "$FAKE_TMUX_STATE/@2.@code_notify_running"
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-preinv\",\"error\":\"\",$(ws projPreInv)}"
run_agy_notifier "$fake_path" "PreInvocation" \
    "{\"conversationId\":\"c-preinv\",\"invocationNum\":1,$(ws projPreInv)}"
[[ -f "$FAKE_TMUX_STATE/@2.@code_notify_running" ]] \
    || fail "PreInvocation did not light the tmux running indicator"
sleep 2
grep -q "projPreInv" "$notification_log" \
    && fail "PreInvocation produced a notification (should be silent, incl. cancelling the debounce)"

# 8c) A Stop whose payload carries the turn's terminal error must raise a
#     failure alert, not "task complete".
run_agy_notifier "$fake_path" "Stop" \
    "{\"conversationId\":\"c-stoperr\",\"error\":\"agent died\",\"terminationReason\":\"ERROR\",$(ws projStopErr)}"
grep -q "Error - projStopErr" "$notification_log" \
    || fail "Stop with an error payload was not classified as a failure"
grep -q "Task Complete - projStopErr" "$notification_log" \
    && fail "Stop with an error payload was also reported as task complete"

# 8d) Once a native Stop has been observed for a conversation, later
#     PostToolUse steps must not arm the debounced fallback: exactly one
#     completion (from the Stop), none from a watcher.
run_agy_notifier "$fake_path" "Stop" \
    "{\"conversationId\":\"c-native\",\"error\":\"\",$(ws projNative)}"
[[ -f "$HOME/.claude/notifications/agy/c-native.native-stop" ]] \
    || fail "native Stop did not record the per-conversation marker"
run_agy_notifier "$fake_path" "PostToolUse" \
    "{\"conversationId\":\"c-native\",\"error\":\"\",$(ws projNative)}"
sleep 2
native_count="$(grep -c "Task Complete - projNative" "$notification_log")"
[[ "$native_count" == "1" ]] \
    || fail "expected exactly 1 completion for projNative, got $native_count (fallback watcher armed despite native Stop)"

# 9) Settle gate: inside tmux, a pane still painting after the last step means
#    the model is generating — the watcher must postpone the completion until
#    the pane holds still for a full quiet window, then fire it. The fake tmux
#    serves capture-pane from a file the test mutates; everything else no-ops.
pane_content="$test_dir/pane_content"
cat > "$fake_bin/tmux" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "capture-pane" ]]; then
    cat "$pane_content" 2>/dev/null
fi
exit 0
EOF
chmod +x "$fake_bin/tmux"

run_agy_notifier_tmux() {
    printf '%s' "$2" \
    | PATH="$fake_path" \
      TMUX="$test_dir/sock,1,0" \
      TMUX_PANE="%9" \
      CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
      CODE_NOTIFY_AGY_DEBOUNCE_SECONDS=1 \
      CODE_NOTIFY_TAIL_SYNC=1 \
      bash "$NOTIFIER" "agy:$1" "antigravity"
}

printf '%s' "model streaming, frame 1" > "$pane_content"
run_agy_notifier_tmux "PostToolUse" \
    "{\"conversationId\":\"c-settle\",\"error\":\"\",$(ws projSettle)}"
# The pane keeps painting through the first quiet window: not done yet.
printf '%s' "model streaming, frame 2" > "$pane_content"
sleep 1.4
grep -q "Task Complete - projSettle" "$notification_log" \
    && fail "completion fired while the pane was still painting"
# The pane settles; the next full quiet window must deliver the completion.
wait_for_lines "$notification_log" "$(( $(wc -l < "$notification_log") + 1 ))" \
    || fail "settled pane did not deliver the postponed completion"
grep -q "Task Complete - projSettle" "$notification_log" \
    || fail "postponed completion was not the settle-gate delivery"

# 9b) A step arriving mid-settle must still cancel the loop: arm with a
#     painting pane, then report an error in the same conversation while the
#     watcher is postponing. No completion may follow.
printf '%s' "still painting A" > "$pane_content"
run_agy_notifier_tmux "PostToolUse" \
    "{\"conversationId\":\"c-settle-cancel\",\"error\":\"\",$(ws projSettleCancel)}"
printf '%s' "still painting B" > "$pane_content"
run_agy_notifier_tmux "PostToolUse" \
    "{\"conversationId\":\"c-settle-cancel\",\"error\":{\"message\":\"mid-settle failure\"},$(ws projSettleCancel)}"
sleep 2.5
grep -q "Task Complete - projSettleCancel" "$notification_log" \
    && fail "mid-settle error did not cancel the postponed completion"
grep -q "Error - projSettleCancel" "$notification_log" \
    || fail "mid-settle error was not reported"

# 10) Regression: a fractional debounce interval ("0.25" is valid for sleep)
#     must not hit bash integer arithmetic — that aborts the whole hook and no
#     watcher ever arms. Outside tmux (TMUX cleared), the completion must
#     still be delivered.
printf '%s' "{\"conversationId\":\"c-frac\",\"error\":\"\",$(ws projFrac)}" \
| PATH="$fake_path" \
  TMUX='' TMUX_PANE='' \
  CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
  CODE_NOTIFY_AGY_DEBOUNCE_SECONDS=0.25 \
  CODE_NOTIFY_TAIL_SYNC=1 \
  bash "$NOTIFIER" "agy:PostToolUse" "antigravity"
wait_for_lines "$notification_log" "$(( $(wc -l < "$notification_log") + 1 ))" \
    || fail "fractional debounce interval did not deliver a completion"
grep -q "Task Complete - projFrac" "$notification_log" \
    || fail "fractional debounce completion was not delivered"
# The delivering StopFinal process may still be writing its own state files;
# give it a moment so the EXIT trap's rm -rf does not race a live writer.
sleep 1

pass "Antigravity maps PreToolUse/PostToolUse/Stop into the correct notifications"
