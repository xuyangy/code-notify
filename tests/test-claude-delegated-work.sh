#!/bin/bash

# Claude Stop payloads expose the current background-task registry. Running
# subagent/teammate entries must defer both completion and the later native
# idle reminder without blocking Claude's control loop.

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

notification_lines() {
    if [[ -f "$notification_log" ]]; then
        wc -l < "$notification_log"
    else
        echo 0
    fi
}

marker_sess1="$HOME/.claude/notifications/state/delegated_work_claude_test-project_sess1"

# A running teammate makes the main Stop non-terminal and leaves a marker for
# Claude's later idle_prompt event.
export TMUX="$test_dir/tmux-socket,1,0"
export TMUX_PANE="%1"
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"team-1","type":"teammate","status":"running","description":"reviewing"}]}'
unset TMUX TMUX_PANE
[[ "$(notification_lines)" -eq 0 ]] || fail "running teammate Stop should not notify"
[[ -f "$marker_sess1" ]] || fail "running teammate Stop should persist delegated-work state"
[[ ! -e "$tmux_log" ]] || fail "suppressed teammate Stop should not mutate tmux state"

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
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"team-2","type":"teammate","status":"running"}]}'
[[ -f "$marker_sess1" ]] || fail "second running teammate should restore marker"

run_notifier stop '{"session_id":"sess2","stop_hook_active":false,"background_tasks":[]}'
[[ "$(notification_lines)" -eq 6 ]] || fail "another session should not inherit delegated-work state"

run_notifier stop '{"session_id":"sess1","stop_hook_active":false}'
[[ "$(notification_lines)" -eq 6 ]] || fail "missing registry should preserve and honor existing state"
[[ -f "$marker_sess1" ]] || fail "missing registry should not clear existing state"

run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[]}'
[[ "$(notification_lines)" -eq 7 ]] || fail "authoritative clear after unknown snapshot should notify"
[[ ! -e "$marker_sess1" ]] || fail "authoritative clear should remove preserved state"

# Lifecycle retirement fixes the information lost by background_tasks:
# TeammateIdle is the only payload that says a serialized-running teammate is
# actually parked, and SubagentStop is the corresponding subagent signal.
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"team-3","type":"teammate","status":"running"}]}'
run_notifier TeammateIdle '{"session_id":"sess1","teammate_name":"reviewer"}'
[[ ! -e "$marker_sess1" ]] || fail "TeammateIdle should retire delegated-work state"
lines_after_teammate_idle="$(notification_lines)"
run_notifier notification '{"session_id":"sess1","notification_type":"idle_prompt"}'
[[ "$(notification_lines)" -eq $((lines_after_teammate_idle + 1)) ]] || fail "idle reminder should resume after TeammateIdle"

run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"agent-2","type":"subagent","status":"running"}]}'
run_notifier SubagentStop '{"session_id":"sess1","agent_id":"agent-2","stop_hook_active":false}'
[[ ! -e "$marker_sess1" ]] || fail "SubagentStop should retire delegated-work state"

# Repeated Stop snapshots do not refresh the marker timestamp. If a lifecycle
# event is lost, the fail-open TTL restores the idle safety net.
run_notifier stop '{"session_id":"sess1","stop_hook_active":false,"background_tasks":[{"id":"team-4","type":"teammate","status":"running"}]}'
old_epoch=$(( $(date +%s) - 7200 ))
printf '%s' "$old_epoch" > "$marker_sess1"
lines_before_expired_idle="$(notification_lines)"
run_notifier notification '{"session_id":"sess1","notification_type":"idle_prompt"}'
[[ "$(notification_lines)" -eq $((lines_before_expired_idle + 1)) ]] || fail "expired delegated-work state should not suppress idle"
[[ ! -e "$marker_sess1" ]] || fail "expired delegated-work state should be pruned"

pass "Claude delegated work defers completion and idle without blocking"
