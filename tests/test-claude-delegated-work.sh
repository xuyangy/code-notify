#!/bin/bash

# Claude Stop payloads expose the current background-task registry. Running
# subagent/workflow entries must defer both completion and the later native
# idle reminder without blocking Claude's control loop. Teammate entries never
# defer.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="$SCRIPT_DIR/../lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
export CODE_NOTIFY_TAIL_SYNC=1
fake_bin="$test_dir/bin"
log_dir="$test_dir/log"
mkdir -p "$HOME/.claude/notifications" "$HOME/.claude/logs" "$fake_bin" "$log_dir"

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
        echo "SKIP: unsupported OS for delegated-work test"
        exit 0
        ;;
esac

chmod +x "$fake_bin"/*
fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Any tmux invocation before the delegated-work guard would be a badge/running
# state mutation. The first suppressed Stop runs with a fake tmux context and
# must exit without touching it.
tmux_log="$log_dir/tmux.log"
cat > "$fake_bin/tmux" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$tmux_log"
exit 1
EOF
chmod +x "$fake_bin/tmux"

run_notifier() {
    local hook_type="$1"
    local payload="$2"

    printf '%s\n' "$payload" | \
        PATH="$fake_path" \
        CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=0 \
        bash "$NOTIFIER" "$hook_type" claude test-project
}

tmux_call_lines() {
    if [[ -f "$tmux_log" ]]; then
        wc -l < "$tmux_log"
    else
        echo 0
    fi
}

notification_lines() {
    if [[ -f "$notification_log" ]]; then
        wc -l < "$notification_log"
    else
        echo 0
    fi
}

marker_sess1="$HOME/.claude/notifications/state/delegated_work_claude_test-project_sess1"

# A running subagent makes the main Stop non-terminal and leaves a marker for
# Claude's later idle_prompt event.
export TMUX="$test_dir/tmux-socket,1,0"
export TMUX_PANE="%1"
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"agent-0","type":"subagent","status":"running","description":"reviewing"}]}'
unset TMUX TMUX_PANE
[[ "$(notification_lines)" -eq 0 ]] || fail "running subagent Stop should not notify"
[[ -f "$marker_sess1" ]] || fail "running subagent Stop should persist delegated-work state"
[[ ! -e "$tmux_log" ]] || fail "suppressed subagent Stop should not mutate tmux state"

run_notifier notification '{"session_id":"sess1","notification_type":"idle_prompt"}'
[[ "$(notification_lines)" -eq 0 ]] || fail "idle_prompt should stay hidden while delegated work is marked running"

# A later authoritative snapshot with no running delegated tasks clears the
# marker and delivers the real completion.
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[]}'
[[ "$(notification_lines)" -eq 1 ]] || fail "empty task snapshot should deliver completion"
[[ ! -e "$marker_sess1" ]] || fail "empty task snapshot should clear delegated-work state"

# Subagents use the same documented registry path. Non-running entries must not
# keep the marker alive.
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"agent-1","type":"subagent","status":"running"}]}'
[[ "$(notification_lines)" -eq 1 ]] || fail "running subagent Stop should not notify"
[[ -f "$marker_sess1" ]] || fail "running subagent Stop should persist delegated-work state"

run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"agent-1","type":"subagent","status":"completed"}]}'
[[ "$(notification_lines)" -eq 2 ]] || fail "completed subagent snapshot should deliver completion"
[[ ! -e "$marker_sess1" ]] || fail "completed subagent snapshot should clear delegated-work state"

# Other background task types do not represent delegated agents and must not
# delay the main agent's completion badge.
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"shell-1","type":"shell","status":"running"}]}'
[[ "$(notification_lines)" -eq 3 ]] || fail "running shell task should not defer agent completion"

run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"agent-pending","type":"subagent","status":"pending"}]}'
[[ "$(notification_lines)" -eq 3 ]] || fail "pending subagent should defer agent completion"
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[]}'
[[ "$(notification_lines)" -eq 4 ]] || fail "pending subagent clear should deliver completion"

run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"cloud-1","type":"cloud session","status":"running"}]}'
[[ "$(notification_lines)" -eq 4 ]] || fail "running cloud session should defer agent completion"
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[]}'
[[ "$(notification_lines)" -eq 5 ]] || fail "cloud session clear should deliver completion"

# Markers are session-scoped. A malformed/unavailable registry preserves known
# state, while a different session remains unaffected.
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"agent-6","type":"subagent","status":"running"}]}'
[[ -f "$marker_sess1" ]] || fail "second running subagent should restore marker"

run_notifier stop '{"session_id":"sess2","stop_hook_active":false,"background_tasks":[]}'
[[ "$(notification_lines)" -eq 6 ]] || fail "another session should not inherit delegated-work state"

run_notifier stop '{"session_id":"sess1","stop_hook_active":false}'
[[ "$(notification_lines)" -eq 6 ]] || fail "missing registry should preserve and honor existing state"
[[ -f "$marker_sess1" ]] || fail "missing registry should not clear existing state"

run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[]}'
[[ "$(notification_lines)" -eq 7 ]] || fail "authoritative clear after unknown snapshot should notify"
[[ ! -e "$marker_sess1" ]] || fail "authoritative clear should remove preserved state"

# SubagentStop retires delegated-work state even before the next Stop
# snapshot confirms it.
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"agent-2","type":"subagent","status":"running"}]}'
run_notifier SubagentStop '{"session_id":"sess1","agent_id":"agent-2","stop_hook_active":false}'
[[ ! -e "$marker_sess1" ]] || fail "SubagentStop should retire delegated-work state"

# A parked teammate serializes as status=running exactly like a working one,
# so a teammate entry never defers completion — not before TeammateIdle, not
# after, and not in a later session of the same Claude process (an in-process
# teammate outlives /clear, and the new session never sees its idle signal).
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"agent-5","type":"subagent","status":"running"}]}'
[[ -f "$marker_sess1" ]] || fail "running subagent should arm delegated-work state"
lines_before_teammate_stop="$(notification_lines)"
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"team-3","type":"teammate","status":"running"}]}'
[[ ! -e "$marker_sess1" ]] || fail "teammate-only Stop should clear delegated-work state"
[[ "$(notification_lines)" -eq $((lines_before_teammate_stop + 1)) ]] ||
    fail "teammate-only Stop should deliver completion"

run_notifier TeammateIdle '{"session_id":"sess1","teammate_name":"reviewer"}'
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"team-3","type":"teammate","status":"running"}]}'
[[ ! -e "$marker_sess1" ]] || fail "teammate after TeammateIdle should not mark delegated work"
[[ "$(notification_lines)" -eq $((lines_before_teammate_stop + 2)) ]] ||
    fail "completion should deliver after TeammateIdle despite the parked teammate"

marker_sess4="$HOME/.claude/notifications/state/delegated_work_claude_test-project_sess4"
run_notifier stop '{"session_id":"sess4","stop_hook_active":false,"background_tasks":[{"id":"team-3","type":"teammate","status":"running"}]}'
[[ ! -e "$marker_sess4" ]] || fail "inherited teammate should not mark a new session"
[[ "$(notification_lines)" -eq $((lines_before_teammate_stop + 3)) ]] ||
    fail "new session should deliver completion despite an inherited teammate"
lines_before_inherited_idle="$(notification_lines)"
run_notifier notification '{"session_id":"sess4","notification_type":"idle_prompt"}'
[[ "$(notification_lines)" -eq $((lines_before_inherited_idle + 1)) ]] ||
    fail "inherited teammate should not suppress the idle reminder"

# A teammate beside a running subagent does not hide the subagent.
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"agent-3","type":"subagent","status":"running"},{"id":"team-3","type":"teammate","status":"running"}]}'
[[ -f "$marker_sess1" ]] || fail "running subagent beside a teammate should defer"
# TeammateIdle carries no state: the marker belongs to the still-running
# subagent, so the idle reminder stays hidden.
lines_before_mixed_idle="$(notification_lines)"
run_notifier TeammateIdle '{"session_id":"sess1","teammate_name":"reviewer"}'
[[ -f "$marker_sess1" ]] || fail "TeammateIdle should not retire a running subagent's marker"
run_notifier notification '{"session_id":"sess1","notification_type":"idle_prompt"}'
[[ "$(notification_lines)" -eq "$lines_before_mixed_idle" ]] ||
    fail "idle reminder should stay hidden while the subagent runs"
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"team-3","type":"teammate","status":"running"}]}'
[[ ! -e "$marker_sess1" ]] || fail "subagent completion should clear the marker despite the parked teammate"

# Repeated Stop snapshots do not refresh the marker timestamp. If a lifecycle
# event is lost, the fail-open TTL restores the idle safety net.
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"agent-4","type":"subagent","status":"running"}]}'
old_epoch=$(( $(date +%s) - 7200 ))
printf '%s' "$old_epoch" > "$marker_sess1"
lines_before_expired_idle="$(notification_lines)"
run_notifier notification '{"session_id":"sess1","notification_type":"idle_prompt"}'
[[ "$(notification_lines)" -eq $((lines_before_expired_idle + 1)) ]] || fail "expired delegated-work state should not suppress idle"
[[ ! -e "$marker_sess1" ]] || fail "expired delegated-work state should be pruned"

# The Workflow tool registers a backgrounded workflow that fans out its own
# agents, so its main-turn Stop is a pause exactly like a delegated subagent's.
marker_sess3="$HOME/.claude/notifications/state/delegated_work_claude_test-project_sess3"
lines_before_workflow="$(notification_lines)"

# The badge assertion only means something with a tmux context present: without
# TMUX/TMUX_PANE, tmux_running_stop returns before it shells out, so an
# unsuppressed Stop would leave the call count unchanged too.
tmux_calls_before_workflow="$(tmux_call_lines)"
export TMUX="$test_dir/tmux-socket,1,0"
export TMUX_PANE="%1"
run_notifier stop '{"session_id":"sess3","stop_hook_active":false,"background_tasks":[{"id":"wf-1","type":"workflow","status":"running","name":"review-changes"}]}'
unset TMUX TMUX_PANE
[[ "$(notification_lines)" -eq "$lines_before_workflow" ]] || fail "running workflow Stop should not notify"
[[ -f "$marker_sess3" ]] || fail "running workflow Stop should persist delegated-work state"
[[ "$(tmux_call_lines)" -eq "$tmux_calls_before_workflow" ]] ||
    fail "suppressed workflow Stop should not mutate tmux state"

run_notifier notification '{"session_id":"sess3","notification_type":"idle_prompt"}'
[[ "$(notification_lines)" -eq "$lines_before_workflow" ]] || fail "running workflow should suppress the idle reminder"

run_notifier stop '{"session_id":"sess3","stop_hook_active":false,"background_tasks":[{"id":"wf-1","type":"workflow","status":"pending"}]}'
[[ "$(notification_lines)" -eq "$lines_before_workflow" ]] || fail "pending workflow should defer agent completion"

# The real terminal snapshot is an empty array: Claude serializes only in-flight
# work, so a finished workflow drops out rather than appearing as completed.
run_notifier stop '{"session_id":"sess3","stop_hook_active":false,"background_tasks":[]}'
[[ "$(notification_lines)" -eq $((lines_before_workflow + 1)) ]] || fail "workflow drop-out should deliver completion"
[[ ! -e "$marker_sess3" ]] || fail "workflow drop-out should clear delegated-work state"

# Defensive only: Claude does not currently serialize a terminal workflow, but
# if it ever did, a non-running status must not hold the completion back.
run_notifier stop '{"session_id":"sess3","stop_hook_active":false,"background_tasks":[{"id":"wf-2","type":"workflow","status":"running"}]}'
[[ -f "$marker_sess3" ]] || fail "second running workflow should re-arm delegated-work state"
run_notifier stop '{"session_id":"sess3","stop_hook_active":false,"background_tasks":[{"id":"wf-2","type":"workflow","status":"completed"}]}'
[[ "$(notification_lines)" -eq $((lines_before_workflow + 2)) ]] || fail "completed workflow entry should deliver completion"
[[ ! -e "$marker_sess3" ]] || fail "completed workflow entry should clear delegated-work state"

pass "Claude delegated work defers completion and idle without blocking"
