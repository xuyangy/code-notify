#!/bin/bash

# Core notification functionality for Code-Notify
# Supports: Claude Code, Codex, Gemini CLI

# Get arguments:
#   Claude/Gemini: notify.sh <hook_type> <tool_name> [project_name]
#   Codex (hooks): notify.sh <hook_type> codex      (payload JSON on stdin)
#   Codex (legacy notify=): notify.sh codex <payload_json>
# The legacy form is retained for users upgrading from the config.toml notify
# integration who have not yet re-run `cn on codex`.
RAW_ARG1="${1:-}"
RAW_ARG2="${2:-}"
RAW_ARG3="${3:-}"

NOTIFIER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# UserPromptSubmit (any agent whose installer registered the hook — Claude,
# Codex): the user just handed this window more work, so clear its badge — the
# accurate "no longer waiting" signal, unlike a mere glance. No notification
# fires for this event. Handled before the utility sourcing below because the
# agent runs this hook synchronously on every prompt submission, so the path
# must stay cheap: it only needs tmux.sh.
# Antigravity exports CLAUDE_HOOK_TYPE for compatibility even though its
# wrappers identify their lifecycle event as agy:<Event> in argv. Keep those
# events on the dedicated Antigravity path below; otherwise an agy PostToolUse
# would be mistaken for a Claude/Codex spinner-resume hook.
if [[ "$RAW_ARG1" != agy:* ]] && [[ "${CLAUDE_HOOK_TYPE:-$RAW_ARG1}" == "UserPromptSubmit" ]]; then
    source "$NOTIFIER_DIR/../utils/tmux.sh"
    # Let tmux.sh associate the marker with the actual agent process, so an
    # explicit tool exit can clear it even though Codex has no SessionEnd hook.
    CODE_NOTIFY_TMUX_AGENT_NAME="${RAW_ARG2:-}"
    # One capture serves both halves: the event badge clears (engage-clear)
    # and the running marker — the agent is now working — replaces it.
    tmux_prompt_submit 2>/dev/null || true
    exit 0
fi

# A direct prompt submission is not the only way an agent resumes: approving a
# command or answering an in-turn question continues the existing turn. Those
# actions do not emit UserPromptSubmit, so the lightweight PostToolUse hook and
# the fallback PreToolUse hook use this path to restore the running indicator.
# tmux_running_resume_after_input itself is gated by a marker set only when the
# notifier observed an input/approval request, making ordinary tool hooks
# no-ops.
if [[ "$RAW_ARG1" != agy:* ]] && {
    [[ "${CLAUDE_HOOK_TYPE:-$RAW_ARG1}" == "PostToolUse" ]] ||
    [[ "${CLAUDE_HOOK_TYPE:-$RAW_ARG1}" == "ResumeAfterInput" ]]
}; then
    source "$NOTIFIER_DIR/../utils/tmux.sh"
    CODE_NOTIFY_TMUX_AGENT_NAME="${RAW_ARG2:-}"
    tmux_running_resume_after_input 2>/dev/null || true
    exit 0
fi

# Source shared utilities
source "$NOTIFIER_DIR/../utils/detect.sh"
source "$NOTIFIER_DIR/../utils/voice.sh"
source "$NOTIFIER_DIR/../utils/sound.sh"
source "$NOTIFIER_DIR/../utils/tts.sh"
source "$NOTIFIER_DIR/../utils/channels.sh"
source "$NOTIFIER_DIR/../utils/usage.sh"
source "$NOTIFIER_DIR/../utils/click-through-store.sh"
source "$NOTIFIER_DIR/../utils/click-through-runtime.sh"
source "$NOTIFIER_DIR/../utils/click-through-resolver.sh"
source "$NOTIFIER_DIR/../utils/tmux.sh"
source "$NOTIFIER_DIR/../utils/snooze.sh"
source "$NOTIFIER_DIR/../utils/persist.sh"

has_jq() {
    command -v jq >/dev/null 2>&1
}

has_python3() {
    command -v python3 >/dev/null 2>&1
}

json_extract_string() {
    local json="$1"
    local key="$2"

    if [[ -z "$json" ]]; then
        return 0
    fi

    if has_jq; then
        printf '%s' "$json" | jq -r --arg key "$key" '(.[$key] // "") | if type == "string" then . else "" end' 2>/dev/null
        return 0
    fi

    if has_python3; then
        printf '%s' "$json" | python3 -c '
import json, sys
key = sys.argv[1]
try:
    value = json.load(sys.stdin).get(key, "")
except Exception:
    value = ""
print(value if isinstance(value, str) else "", end="")
' "$key" 2>/dev/null
        return 0
    fi

    case "$key" in
        "type")
            printf '%s' "$json" | sed -nE 's/.*"type"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
            ;;
        "notification_type")
            printf '%s' "$json" | sed -nE 's/.*"notification_type"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
            ;;
        "cwd")
            printf '%s' "$json" | sed -nE 's/.*"cwd"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
            ;;
        "conversationId")
            # Needed so Antigravity debounce tokens stay per-conversation even
            # without jq/python3; otherwise every session collapses onto the
            # default token and concurrent turns cancel each other's completion.
            printf '%s' "$json" | sed -nE 's/.*"conversationId"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
            ;;
    esac
}

# Extract the payload's type ("type", falling back to "notification_type")
# in a single interpreter spawn — this runs before every notification, so
# spawn count directly delays the banner.
get_payload_type_field() {
    local json="$1"

    if [[ -z "$json" ]]; then
        return 0
    fi

    if has_jq; then
        printf '%s' "$json" | jq -r '(((.type | strings) // (.notification_type | strings)) // "")' 2>/dev/null
        return 0
    fi

    if has_python3; then
        printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    value = data.get("type") or data.get("notification_type") or ""
except Exception:
    value = ""
print(value if isinstance(value, str) else "", end="")
' 2>/dev/null
        return 0
    fi

    local value
    value=$(json_extract_string "$json" "type")
    if [[ -z "$value" ]]; then
        value=$(json_extract_string "$json" "notification_type")
    fi
    printf '%s' "$value"
}

get_codex_hook_type() {
    local payload_type
    payload_type=$(json_extract_string "$HOOK_DATA" "type" | tr '[:upper:]' '[:lower:]')

    case "$payload_type" in
        "agent-turn-complete")
            printf '%s\n' "stop"
            return 0
            ;;
        *"request_permissions"*|*"permission"*|*"approval"*|*"elicitation"*|*"prompt"*)
            printf '%s\n' "notification"
            return 0
            ;;
        *"error"*|*"failed"*)
            printf '%s\n' "error"
            return 0
            ;;
    esac

    if [[ "$HOOK_DATA" == *"last-assistant-message"* ]]; then
        printf '%s\n' "stop"
    elif [[ "$HOOK_DATA" == *"request_permissions"* ]] || [[ "$HOOK_DATA" == *"approval"* ]] || [[ "$HOOK_DATA" == *"permission"* ]]; then
        printf '%s\n' "notification"
    else
        printf '%s\n' "stop"
    fi
}

get_codex_project_name() {
    local payload_cwd
    payload_cwd=$(json_extract_string "$HOOK_DATA" "cwd")

    if [[ -n "$payload_cwd" ]]; then
        basename "$payload_cwd"
    else
        basename "$PWD"
    fi
}

# --- Antigravity CLI (agy) payload helpers ---
# agy hooks deliver a JSON payload on stdin and pass no argv; the calling
# wrapper encodes the lifecycle event as the first arg ("agy:<Event>").

# Absolute path to this notifier, used to re-invoke ourselves from the
# debounce watcher (notifier.sh does not source config.sh / get_notify_script).
SELF_NOTIFIER="$NOTIFIER_DIR/$(basename "${BASH_SOURCE[0]}")"

# Project name from the first workspace path (falls back to cwd).
get_agy_project_name() {
    local ws=""
    if has_jq; then
        ws=$(printf '%s' "$HOOK_DATA" | jq -r '(.workspacePaths[0] // "")' 2>/dev/null)
    elif has_python3; then
        ws=$(printf '%s' "$HOOK_DATA" | python3 -c '
import json, sys
try:
    paths = json.load(sys.stdin).get("workspacePaths") or []
    print(paths[0] if paths else "", end="")
except Exception:
    print("", end="")
' 2>/dev/null)
    fi
    if [[ -n "$ws" ]]; then
        basename "$ws"
    else
        basename "$PWD"
    fi
}

# Returns non-empty when the payload reports a tool failure. agy may send
# `error` as a plain string OR as a structured HookErrorMessage object, so a
# string-only check would misclassify real failures as success.
get_agy_error() {
    if has_jq; then
        printf '%s' "$HOOK_DATA" | jq -r '
            (.error // empty) as $e
            | if   ($e | type) == "string" then $e
              elif ($e | type) == "object" then (if ($e | length) > 0 then ($e.message // "error") else "" end)
              elif ($e | type) == "null"   then ""
              else ($e | tostring) end' 2>/dev/null
        return 0
    fi
    if has_python3; then
        printf '%s' "$HOOK_DATA" | python3 -c '
import json, sys
try:
    e = json.load(sys.stdin).get("error")
except Exception:
    e = None
if e is None:
    print("", end="")
elif isinstance(e, str):
    print(e, end="")
elif isinstance(e, dict):
    print((e.get("message") or "error") if e else "", end="")
else:
    print(str(e), end="")
' 2>/dev/null
        return 0
    fi
    # Last resort (no jq/python): regex on the raw payload. An empty string
    # error (`"error":""`) is success; a non-empty string or an object
    # (`"error":{...}`) is a failure. Matching the empty form first avoids
    # misreading a structured failure as success.
    if printf '%s' "$HOOK_DATA" | grep -Eq '"error"[[:space:]]*:[[:space:]]*""'; then
        return 0
    fi
    if printf '%s' "$HOOK_DATA" | grep -Eq '"error"[[:space:]]*:[[:space:]]*("[^"]|\{)'; then
        printf '%s' "error"
    fi
}

get_agy_conversation_id() {
    local cid
    cid=$(json_extract_string "$HOOK_DATA" "conversationId")
    printf '%s' "${cid:-default}"
}

# Tool name for the current tool event (.toolCall.name); empty for model-only
# steps. Used to scope the approval ("input needed") banner to calls that
# actually pause for the user (run_command).
get_agy_tool_name() {
    if has_jq; then
        printf '%s' "$HOOK_DATA" | jq -r '(.toolCall.name // "")' 2>/dev/null
        return 0
    fi
    if has_python3; then
        printf '%s' "$HOOK_DATA" | python3 -c '
import json, sys
try:
    tc = json.load(sys.stdin).get("toolCall") or {}
    print(tc.get("name") or "", end="")
except Exception:
    print("", end="")
' 2>/dev/null
        return 0
    fi
    # sed fallback (no jq/python3): json_extract_string only knows top-level
    # keys, and a bare "name" match could hit any other "name" key in the
    # payload. Scope the match to the toolCall object instead; [^{}]* keeps it
    # from crossing into a nested object, so an unmatched payload (name after a
    # nested object, or pretty-printed across lines) yields "" — no banner,
    # same as a model-only step.
    printf '%s' "$HOOK_DATA" | sed -nE \
        's/.*"toolCall"[[:space:]]*:[[:space:]]*\{[^{}]*"name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
}

# The shell command a run_command tool event will run (.toolCall.args.CommandLine);
# empty when absent. Same jq -> python3 -> sed ladder as get_agy_tool_name.
get_agy_command_line() {
    if has_jq; then
        printf '%s' "$HOOK_DATA" | jq -r '(.toolCall.args.CommandLine // "")' 2>/dev/null
        return 0
    fi
    if has_python3; then
        printf '%s' "$HOOK_DATA" | python3 -c '
import json, sys
try:
    args = (json.load(sys.stdin).get("toolCall") or {}).get("args") or {}
    print(args.get("CommandLine") or "", end="")
except Exception:
    print("", end="")
' 2>/dev/null
        return 0
    fi
    printf '%s' "$HOOK_DATA" | sed -nE \
        's/.*"toolCall"[[:space:]]*:[[:space:]]*\{.*"CommandLine"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
}

# Path to agy's permission settings (permissions.allow/ask/deny). Overridable
# for tests and non-default installs.
agy_permissions_file() {
    printf '%s' "${CODE_NOTIFY_AGY_SETTINGS:-$HOME/.gemini/antigravity-cli/settings.json}"
}

# Resolve what agy will do with a command against its own permission lists:
# prints "auto" when it runs without prompting (matched allow, or auto-denied),
# or "ask" when it pauses for the user. Precedence is deny > ask > allow (per
# https://antigravity.google/docs/cli/permissions); an unlisted command
# defaults to "ask". Rules are command(<prefix>) and match when their words are
# a leading prefix of the command's words, so command(git) covers "git status"
# but not "git-foo", and command(git add) is checked before command(git).
# Unreadable/absent settings or no parser -> "ask" (never suppress blindly).
agy_permission_decision() {
    local cmd="$1" settings out
    settings="$(agy_permissions_file)"
    [[ -f "$settings" ]] || { printf 'ask'; return 0; }

    # shellcheck disable=SC2016  # $cmd/$ct/$pt are jq variables, not shell
    local jq_prog='
def cmdtoks: ($cmd | split(" ") | map(select(. != "")));
def pats(l): (.permissions[l] // [])
  | map(select(type == "string" and test("^command\\(.*\\)$")))
  | map(sub("^command\\("; "") | sub("\\)$"; ""))
  | map(split(" ") | map(select(. != "")));
def anymatch(l): cmdtoks as $ct
  | (pats(l) | any(. as $pt | ($pt | length) > 0 and $ct[0:($pt | length)] == $pt));
if (cmdtoks | length) == 0 then "ask"
elif anymatch("deny") then "auto"
elif anymatch("ask") then "ask"
elif anymatch("allow") then "auto"
else "ask" end'

    if has_jq; then
        out=$(jq -r --arg cmd "$cmd" "$jq_prog" "$settings" 2>/dev/null)
        [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
    fi
    if has_python3; then
        out=$(python3 - "$cmd" "$settings" <<'PY' 2>/dev/null
import json, sys
cmd, path = sys.argv[1], sys.argv[2]
def toks(s): return [t for t in s.split(" ") if t]
try:
    with open(path) as f:
        perms = json.load(f).get("permissions") or {}
except Exception:
    print("ask", end=""); sys.exit(0)
ct = toks(cmd)
def pats(l):
    out = []
    for e in (perms.get(l) or []):
        if isinstance(e, str) and e.startswith("command(") and e.endswith(")"):
            out.append(toks(e[len("command("):-1]))
    return out
def anymatch(l):
    return any(pt and ct[:len(pt)] == pt for pt in pats(l))
if not ct: print("ask", end="")
elif anymatch("deny"): print("auto", end="")
elif anymatch("ask"): print("ask", end="")
elif anymatch("allow"): print("auto", end="")
else: print("ask", end="")
PY
)
        [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
    fi
    printf 'ask'
}

# Whether a run_command tool event should raise the approval banner: true only
# when agy will actually pause for the user. agy's PreToolUse payload carries no
# approval flag (every run_command looks identical), so the decision is
# reconstructed from agy's own permission lists via agy_permission_decision.
# Commands with shell chaining/redirection are treated as "ask" — the leading
# command may auto-run while a chained one prompts, and over-notifying beats
# swallowing a real prompt.
agy_command_needs_approval() {
    local cmd="$1"
    [[ -n "$cmd" ]] || return 0
    # shellcheck disable=SC2016  # these are literal shell-operator glob patterns
    case "$cmd" in
        *';'* | *'|'* | *'&'* | *'`'* | *'$('* | *'>'* | *'<'* | *$'\n'*) return 0 ;;
    esac
    [[ "$(agy_permission_decision "$cmd")" != "auto" ]]
}

# True when permission_prompt alerts are enabled. The notifier does not source
# config.sh, so read the same notify-types file config.sh writes (normalized,
# pipe-separated). Absent file means the default (idle_prompt only) — approval
# prompts off — matching config.sh's DEFAULT_NOTIFY_TYPE.
agy_permission_prompt_enabled() {
    local types_file="$HOME/.claude/notifications/notify-types"
    local current="idle_prompt"
    [[ -f "$types_file" ]] && current="$(cat "$types_file" 2>/dev/null)"
    [[ "$current" == *permission_prompt* ]]
}

# Debounce PostToolUse into a single "task complete": agy 1.0.11 fires no usable
# Stop event, and PostToolUse fires after every step (including model-only
# steps), so we treat the agent as done once step activity has been quiet for a
# few seconds. Each call stamps a token and arms a detached watcher; only the
# most recent watcher (whose token is still current after the quiet period)
# sends the notification.
#
# Tool runs no longer trip this early: PreToolUse (empty matcher, every tool)
# cancels the pending watcher when the next tool starts, so a tool that outlives
# the quiet window can't fire a premature completion.
#
# Heuristic caveat (no real turn-end event exists yet): a single long *model*
# generation that exceeds the quiet window with no following tool can still fire
# early. The quiet window (CODE_NOTIFY_AGY_DEBOUNCE_SECONDS, default 8s) plus the
# global stop rate limit keep this in check; repeated completions are not cooled
# down per conversation, because that would also swallow legitimate completions
# of quick back-to-back turns in the same session.
#
# Inside tmux the watcher additionally gates the completion on the pane having
# SETTLED: agy paints the pane continuously while generating and its idle
# prompt is static, so "no step for a quiet window" only counts as done once
# the pane content (capture-pane checksum) also held still for a full window.
# A changing pane re-arms the watcher instead of firing, which closes the
# long-generation hole above. The postponement is bounded by
# CODE_NOTIFY_AGY_SETTLE_MAX_SECONDS (default 120, 0 disables the gate): past
# it the watcher fires on the step-quiet signal alone, so a pane that never
# settles (unexpected animation, another process writing to it) degrades to
# the old behavior instead of never notifying. Outside tmux there is no pane
# to observe and the step-quiet heuristic stands alone, as before.

# Path of the per-conversation debounce token. The token is the single source of
# truth for "is a completion still pending": a newer step or an error overwrites
# it, which cancels any watcher still sleeping on the old value.
agy_debounce_tokenfile() {
    local state_dir cid_safe
    state_dir="$HOME/.claude/notifications/agy"
    mkdir -p "$state_dir"
    # Inline sanitize: sanitize_rate_limit_key is defined later in this file
    # than these helpers are invoked, so we can't rely on it here.
    cid_safe="$(get_agy_conversation_id | tr -c 'A-Za-z0-9._-' '_')"
    printf '%s/%s.token' "$state_dir" "$cid_safe"
}

# Per-conversation marker that prevents tmux_running_start from firing on every
# PreToolUse in a turn.  The first PreToolUse of a turn creates this file and
# lights the indicator; subsequent PreToolUse calls see the file and skip the
# tmux IPC entirely.  Turn-end events (StopFinal/Stop/error) remove it so the
# next turn re-arms, and a permission prompt removes it so the first tool call
# after approval restarts the paused indicator.
agy_running_markerfile() {
    local state_dir cid_safe
    state_dir="$HOME/.claude/notifications/agy"
    mkdir -p "$state_dir"
    cid_safe="$(get_agy_conversation_id | tr -c 'A-Za-z0-9._-' '_')"
    printf '%s/%s.running' "$state_dir" "$cid_safe"
}

# Start the running indicator if this is the first tool call of the turn.
# A marker older than TMUX_RUNNING_TTL is ignored: a turn that ended without
# any hook (Escape-interrupt — the case the TTL exists for) leaves its marker
# behind, and honouring it would keep the whole next turn unlit. The indicator
# itself self-expires at the same TTL, so past it the marker is dead weight.
agy_maybe_start_running() {
    local marker now stamp=""
    marker="$(agy_running_markerfile)"
    now="$(date +%s)"
    if [[ -r "$marker" ]]; then
        read -r stamp < "$marker" 2>/dev/null || true
        if [[ "$stamp" =~ ^[0-9]+$ ]] && [[ $((now - stamp)) -lt "$TMUX_RUNNING_TTL" ]]; then
            return 0
        fi
    fi
    printf '%s' "$now" > "$marker" 2>/dev/null || true
    tmux_running_start 2>/dev/null || true
}

# Clear the per-conversation running marker so the next turn re-arms.
agy_clear_running_marker() {
    rm -f "$(agy_running_markerfile)" 2>/dev/null || true
}

# Serialize the running-indicator transition with a debounce completion.  The
# token check alone is not enough: a new PreToolUse can invalidate the token
# after StopFinal checks it but before StopFinal clears the marker/stops tmux.
# mkdir is atomic, and the pid file lets later hooks recover a lock left by a
# killed hook process.
agy_with_running_lock() {
    local lockdir owner attempts=0 status
    lockdir="$(agy_running_markerfile).lock"
    while ! mkdir "$lockdir" 2>/dev/null; do
        if (( attempts >= 500 )); then
            owner=""
            if [[ -r "$lockdir/pid" ]]; then
                # read exits nonzero on the newline-less pid file even though
                # it populates owner, so its status is deliberately ignored.
                read -r owner < "$lockdir/pid" 2>/dev/null || true
            fi
            if [[ "$owner" =~ ^[0-9]+$ ]]; then
                if ! kill -0 "$owner" 2>/dev/null; then
                    rm -f "$lockdir/pid" 2>/dev/null || true
                    rmdir "$lockdir" 2>/dev/null || true
                fi
            elif [[ ! -e "$lockdir/pid" ]]; then
                # The owner may have been killed between mkdir and writing its
                # pid.  The empty directory is safe to reclaim.
                rmdir "$lockdir" 2>/dev/null || true
            fi
            attempts=0
        fi
        ((attempts++))
        sleep 0.01
    done
    printf '%s' "$$" > "$lockdir/pid" 2>/dev/null || true
    "$@"
    status=$?
    rm -f "$lockdir/pid" 2>/dev/null || true
    rmdir "$lockdir" 2>/dev/null || true
    return "$status"
}

agy_start_running_locked() {
    cancel_agy_debounced_stop
    agy_maybe_start_running
}

agy_stop_final_locked() {
    local expected_token="$1" current_token
    current_token="$(cat "$(agy_debounce_tokenfile)" 2>/dev/null || true)"
    [[ -n "$expected_token" ]] && [[ "$current_token" == "$expected_token" ]] || return 1
    agy_clear_running_marker
    tmux_running_stop 2>/dev/null || true
}

# Remove stale per-conversation debounce tokens. A token only matters for the
# few seconds a watcher sleeps on it; once that window passes the file is dead
# weight. Without pruning, every Antigravity conversation leaves one tiny file
# behind forever (the key is the conversation id, so it is never reused). Runs
# best-effort and backgrounded so it never adds latency to the hook.
prune_agy_debounce_tokens() {
    local state_dir retention_days
    state_dir="$HOME/.claude/notifications/agy"
    [[ -d "$state_dir" ]] || return 0
    retention_days="${CODE_NOTIFY_AGY_TOKEN_RETENTION_DAYS:-3}"
    [[ "$retention_days" =~ ^[0-9]+$ ]] || retention_days=3
    find "$state_dir" -maxdepth 1 -type f \
        \( -name '*.token' -o -name '*.completed' -o -name '*.running' \) \
        -mtime "+${retention_days}" -delete 2>/dev/null || true
    # A .running.lock directory this old is a hook killed mid-transition:
    # legitimate holds last milliseconds, and both mkdir and the pid write
    # refresh the dir mtime, so an old dir cannot be live. rm -rf (not
    # -delete) because the leftover pid file makes the dir non-empty, and
    # deleting it first would freshen the dir mtime out of the stale set.
    find "$state_dir" -maxdepth 1 -type d -name '*.running.lock' \
        -mtime "+${retention_days}" -exec rm -rf {} + 2>/dev/null || true
}

# Throttle wrapper around the prune. The stale-file set only changes on a day
# boundary, so scanning the directory on every tool step is pure waste. We stamp
# the last sweep in a tiny file and skip until the interval (default 24h) has
# elapsed -- the common path is one `read` from that file plus an integer
# compare, with no process spawn and no directory scan. $1 is the current epoch,
# reused from the caller so we add zero extra `date` calls.
maybe_prune_agy_debounce_tokens() {
    local now="$1" stamp last interval
    interval="${CODE_NOTIFY_AGY_PRUNE_INTERVAL_SECONDS:-86400}"
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=86400
    stamp="$HOME/.claude/notifications/agy/.last-prune"
    last=0
    [[ -r "$stamp" ]] && read -r last < "$stamp" 2>/dev/null
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now - last < interval )) && return 0
    printf '%s' "$now" > "$stamp" 2>/dev/null || true
    prune_agy_debounce_tokens >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# Cancel any pending debounced completion for this conversation. Used when a
# later step reports an error: that error supersedes the earlier "looks done"
# guess, so we must not also fire a "task complete".
cancel_agy_debounced_stop() {
    printf 'cancelled-%s-%s' "$(date +%s)" "$RANDOM" > "$(agy_debounce_tokenfile)" 2>/dev/null || true
}

schedule_agy_debounced_stop() {
    local now tokenfile token delay
    now="$(date +%s)"
    tokenfile="$(agy_debounce_tokenfile)"
    token="${now}-$$-$RANDOM"
    printf '%s' "$token" > "$tokenfile"
    delay="${CODE_NOTIFY_AGY_DEBOUNCE_SECONDS:-8}"

    # Clean up old tokens from past conversations, throttled to ~once/day so this
    # is effectively free on the per-step hot path.
    maybe_prune_agy_debounce_tokens "$now"

    # Snapshot the pane for the settle gate (see the comment block above the
    # token helpers). Empty when disabled or outside tmux, which turns the
    # gate off in the watcher. The deadline deliberately excludes the delay:
    # CODE_NOTIFY_AGY_DEBOUNCE_SECONDS may be fractional ("0.25") — sleep
    # accepts that, but bash integer arithmetic aborts the whole hook on it,
    # so the delay must never appear in $((...)). Measuring the bound from
    # arming rather than from the first wake costs at most one quiet window
    # of postponement headroom.
    local settle_fp="" settle_deadline settle_max
    settle_max="${CODE_NOTIFY_AGY_SETTLE_MAX_SECONDS:-120}"
    [[ "$settle_max" =~ ^[0-9]+$ ]] || settle_max=120
    if (( settle_max > 0 )) && tmux_focus_available; then
        settle_fp="$(tmux_resume_poll_fingerprint "$TMUX_PANE")"
    fi
    settle_deadline=$((now + settle_max))

    (
        while :; do
            sleep "$delay"
            # Only the latest activity wins; a newer step or an error overwrites
            # the token, so earlier/cancelled watchers bail out here — checked
            # every round, so a step arriving mid-settle cancels the loop too.
            [[ "$(cat "$tokenfile" 2>/dev/null)" == "$token" ]] || exit 0
            # Settle gate: a pane that painted during the quiet window is a
            # model still generating, not a finished turn — re-arm on the new
            # snapshot. Past the deadline (or when capture fails) fire on the
            # step-quiet signal alone.
            if [[ -n "$settle_fp" ]] && (( $(date +%s) < settle_deadline )); then
                fp_now="$(tmux_resume_poll_fingerprint "$TMUX_PANE")"
                if [[ -n "$fp_now" ]] && [[ "$fp_now" != "$settle_fp" ]]; then
                    settle_fp="$fp_now"
                    continue
                fi
            fi
            # Carry the token into StopFinal so that the completion is
            # revalidated after the watcher crosses the process boundary.
            printf '%s' "$HOOK_DATA" | "$SELF_NOTIFIER" "agy:StopFinal" "antigravity" "$token" >/dev/null 2>&1
            exit 0
        done
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

AGY_FORCED_SUBTYPE=""
AGY_STOP_FINAL_CLEANUP=0
HOOK_DATA=""
if [[ "$RAW_ARG1" == "codex" ]]; then
    TOOL_NAME="codex"
    HOOK_DATA="$RAW_ARG2"
    HOOK_TYPE=$(get_codex_hook_type)
    PROJECT_NAME="${RAW_ARG3:-$(get_codex_project_name)}"
elif [[ "$RAW_ARG1" == agy:* ]]; then
    # Antigravity CLI: "agy:<Event>" + payload on stdin.
    TOOL_NAME="antigravity"
    CODE_NOTIFY_TMUX_AGENT_NAME="$TOOL_NAME"
    AGY_EVENT="${RAW_ARG1#agy:}"
    if [[ ! -t 0 ]]; then
        HOOK_DATA=$(cat 2>/dev/null || true)
    fi
    PROJECT_NAME="$(get_agy_project_name)"
    case "$AGY_EVENT" in
        PreToolUse)
            # agy 1.0.11 fires PreToolUse before EVERY tool call (registered
            # with an empty matcher), so it is code-notify's "agent is still
            # working" signal: a tool is about to run, therefore any pending
            # "looks done" debounce from the previous step is wrong — cancel it.
            # Without this, a tool that outlives the debounce window (e.g. a slow
            # file read between two quick steps) lets the previous step's watcher
            # fire a bogus "task complete" mid-turn.
            # Cancel the debounce and possibly start tmux as one transaction
            # with StopFinal, so a completion cannot stop a newly started turn.
            agy_with_running_lock agy_start_running_locked || true
            # The approval banner is only meaningful for calls that pause for the
            # user (run_command), only when permission_prompt alerts are on, and
            # only when agy will actually stop to ask — commands its permission
            # lists auto-run (e.g. an allowlisted "git status") fire PreToolUse
            # too but never prompt, so bannering them is just noise. Every other
            # tool start is silent — it just cancelled the debounce.
            if [[ "$(get_agy_tool_name)" == "run_command" ]] && agy_permission_prompt_enabled &&
                agy_command_needs_approval "$(get_agy_command_line)"; then
                HOOK_TYPE="notification"
                AGY_FORCED_SUBTYPE="permission_prompt"
                # This notification pauses the running indicator further down.
                # Drop the marker so the next PreToolUse — the first tool call
                # after the user approves — re-lights it via tmux_running_start
                # (which also retires the window's resume-pending flag). agy
                # has no PostToolUse resume shim, so without this the indicator
                # would stay paused for the rest of the turn.
                agy_clear_running_marker
            else
                exit 0
            fi
            ;;
        PostToolUse)
            if [[ -n "$(get_agy_error)" ]]; then
                # A failing step supersedes any earlier "looks done" guess, so
                # cancel the pending debounce before raising the error alert.
                HOOK_TYPE="error"
                cancel_agy_debounced_stop
                agy_clear_running_marker
            else
                HOOK_TYPE="agy_debounce_stop"
            fi
            ;;
        StopFinal)
            # Emitted by our own debounce watcher once step activity went quiet.
            # Revalidate the token while holding the same lock used by
            # PreToolUse. If a newer turn won the race, this completion is stale
            # and must not stop the newer turn's indicator or notify for it.
            agy_with_running_lock agy_stop_final_locked "$RAW_ARG3" || exit 0
            HOOK_TYPE="stop"
            # tmux_running_stop already ran inside the lock; skipping the
            # generic cleanup below keeps a newer PreToolUse from being stopped
            # after the lock is released.
            AGY_STOP_FINAL_CLEANUP=1
            ;;
        Stop)
            # Native lifecycle Stop (inert in agy 1.0.11, ready for when it
            # lands). A real turn-end supersedes our PostToolUse guess, so cancel
            # any pending debounced completion for this conversation to avoid a
            # duplicate "task complete" from the watcher.
            HOOK_TYPE="stop"
            cancel_agy_debounced_stop
            agy_clear_running_marker
            ;;
        *)
            HOOK_TYPE="stop"
            ;;
    esac
else
    HOOK_TYPE=${CLAUDE_HOOK_TYPE:-$RAW_ARG1}
    TOOL_NAME="${RAW_ARG2:-""}"
    PROJECT_NAME="${RAW_ARG3:-$(basename "$PWD")}"

    # Read hook data from stdin (Claude Code passes JSON with hook context)
    if [[ ! -t 0 ]]; then
        HOOK_DATA=$(cat 2>/dev/null || true)
    fi
fi

# tmux helpers use this only to find the agent ancestor of a hook shell. It is
# deliberately set after TOOL_NAME has been resolved rather than inferred from
# a pane command, which can temporarily be a child tool such as git or bash.
# shellcheck disable=SC2034  # read by the sourced tmux.sh, not this file
CODE_NOTIFY_TMUX_AGENT_NAME="$TOOL_NAME"

# Antigravity PostToolUse with no error: arm the debounced "task complete" and
# return immediately (no banner for intermediate steps).
if [[ "$HOOK_TYPE" == "agy_debounce_stop" ]]; then
    schedule_agy_debounced_stop
    exit 0
fi

# How this agent's badges clear (stored per badge — see tmux_badge_set):
#   - "engage": the next reliable work signal clears the badge when the user
#     actually hands the window work (UserPromptSubmit for Claude/Codex, first
#     PreToolUse for Antigravity), so
#     glance-clearing (sweep + focus hook + macOS click-to-clear) is suppressed
#     and the badge survives mere peeks at the output.
#   - "glance": no prompt-submit signal is wired, so visiting the window must
#     clear the badge or nothing will.
# Claude's installer always registers the UserPromptSubmit hook alongside its
# others. Antigravity's all-tools PreToolUse hook is its equivalent engagement
# signal. Codex supports UserPromptSubmit too (hooks.json), but only installs
# that have re-run `cn on codex` since it was added carry it — so engage-clear
# is gated on the hook actually being present in hooks.json, never leaving a
# badge without a clear path (legacy `notify =` users and stale hooks.json
# files keep glance-clearing). Keyed off TOOL_NAME, which is resolved above
# for every entry path (codex/antigravity/claude/gemini).
# Matches the managed Code-Notify command (notifier.sh/notify.sh/notify.ps1
# invoked with "UserPromptSubmit codex"), not just the event name: a user's own
# unrelated UserPromptSubmit hook won't clear our badge, so it must not switch
# Codex to engage mode — that would leave badges with no clear path.
codex_prompt_clear_hook_installed() {
    local hooks_file="${CODE_NOTIFY_CODEX_HOOKS_FILE:-${CODEX_HOME:-$HOME/.codex}/hooks.json}"
    [[ -f "$hooks_file" ]] || return 1
    grep -Eq '(notifier\.sh|notify\.(sh|ps1))[^"]* UserPromptSubmit codex' "$hooks_file" 2>/dev/null
}

BADGE_CLEAR_MODE="glance"
case "$TOOL_NAME" in
    "claude")
        BADGE_CLEAR_MODE="engage"
        ;;
    "codex")
        if codex_prompt_clear_hook_installed; then
            BADGE_CLEAR_MODE="engage"
        fi
        ;;
    "antigravity")
        BADGE_CLEAR_MODE="engage"
        ;;
esac

badge_glance_clear_enabled() {
    [[ "$BADGE_CLEAR_MODE" == "glance" ]]
}

# Get display name for tool
get_tool_display_name() {
    local tool="$1"
    case "$tool" in
        "claude") echo "Claude" ;;
        "codex") echo "Codex" ;;
        "gemini") echo "Gemini" ;;
        "antigravity") echo "Antigravity" ;;
        *) echo "AI" ;;
    esac
}

TOOL_DISPLAY=$(get_tool_display_name "$TOOL_NAME")

# Rate limiting for stop notifications (prevents spam from parallel sub-agents)
NOTIFICATIONS_DIR="$HOME/.claude/notifications"
RATE_LIMIT_DIR="$NOTIFICATIONS_DIR/state"
STOP_RATE_LIMIT_SECONDS="${CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS:-10}"
NOTIFICATION_RATE_LIMIT_SECONDS="${CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS:-180}"
EVENT_RATE_LIMIT_SECONDS="${CODE_NOTIFY_EVENT_RATE_LIMIT_SECONDS:-10}"

sanitize_rate_limit_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

get_rate_limit_file() {
    local key
    key=$(sanitize_rate_limit_key "$1")
    printf '%s/%s\n' "$RATE_LIMIT_DIR" "$key"
}

get_legacy_rate_limit_file() {
    local key
    key=$(sanitize_rate_limit_key "$1")
    printf '%s/%s\n' "$NOTIFICATIONS_DIR" "$key"
}

get_notification_subtype() {
    # Match approval/permission tokens against the structured type field when
    # the payload has one, so free-form message text containing words like
    # "permission" or "approved" can't misclassify (and bypass rate limiting).
    # Untyped payloads (Claude Code Notification hooks only carry a message)
    # keep the raw substring match.
    local payload_type permission_source
    payload_type=$(get_payload_type_field "$HOOK_DATA")
    # Lowercase for case-insensitive matching — gemini sends capitalised
    # types like "ToolPermission" (PowerShell's -match is already
    # case-insensitive, keeping the two implementations in parity).
    permission_source=$(printf '%s' "${payload_type:-$HOOK_DATA}" | tr '[:upper:]' '[:lower:]')

    if [[ "$HOOK_DATA" == *"idle_prompt"* ]]; then
        printf '%s\n' "idle_prompt"
        return 0
    fi

    if [[ "$permission_source" == *"permission_prompt"* ]] ||
        [[ "$permission_source" == *"request_permissions"* ]] ||
        [[ "$permission_source" == *"sandbox_approval"* ]] ||
        [[ "$permission_source" == *"approval"* ]] ||
        [[ "$permission_source" == *"approve"* ]] ||
        [[ "$permission_source" == *"permission"* ]]; then
        printf '%s\n' "permission_prompt"
        return 0
    fi

    if [[ "$HOOK_DATA" == *"auth_success"* ]]; then
        printf '%s\n' "auth_success"
        return 0
    fi

    if [[ "$HOOK_DATA" == *"elicitation_dialog"* ]] || [[ "$HOOK_DATA" == *"mcp_elicitations"* ]]; then
        printf '%s\n' "elicitation_dialog"
        return 0
    fi

    printf '%s\n' "notification"
}

should_rate_limit_notification_subtype() {
    case "$1" in
        "permission_prompt"|"elicitation_dialog")
            return 1
            ;;
    esac

    return 0
}

get_notification_rate_limit_key() {
    local subtype="${1:-}"
    if [[ -z "$subtype" ]]; then
        subtype=$(get_notification_subtype)
    fi
    printf '%s\n' "last_notification_${TOOL_NAME}_${PROJECT_NAME}_${subtype}"
}

is_claude_event_hook() {
    case "$HOOK_TYPE" in
        "SubagentStart"|"SubagentStop"|"TeammateIdle"|"TaskCreated"|"TaskCompleted")
            return 0
            ;;
    esac
    return 1
}

get_event_rate_limit_key() {
    printf '%s\n' "last_event_${TOOL_NAME}_${PROJECT_NAME}_${HOOK_TYPE}"
}

is_rate_limited() {
    local rate_limit_key="$1"
    local rate_limit_seconds="$2"
    local lock_file legacy_lock_file
    lock_file=$(get_rate_limit_file "$rate_limit_key")
    legacy_lock_file=$(get_legacy_rate_limit_file "$rate_limit_key")

    if [[ ! -f "$lock_file" ]] && [[ -f "$legacy_lock_file" ]]; then
        lock_file="$legacy_lock_file"
    fi

    if [[ ! -f "$lock_file" ]]; then
        return 1  # No previous notification, not rate limited
    fi

    local last_time
    last_time=$(cat "$lock_file" 2>/dev/null || echo "0")
    local current_time
    current_time=$(date +%s)
    local elapsed=$((current_time - last_time))

    if [[ $elapsed -lt $rate_limit_seconds ]]; then
        return 0  # Rate limited
    fi

    return 1  # Not rate limited
}

update_rate_limit() {
    local rate_limit_key="$1"
    local lock_file legacy_lock_file
    lock_file=$(get_rate_limit_file "$rate_limit_key")
    legacy_lock_file=$(get_legacy_rate_limit_file "$rate_limit_key")
    mkdir -p "$RATE_LIMIT_DIR"
    date +%s > "$lock_file"
    if [[ "$legacy_lock_file" != "$lock_file" ]]; then
        rm -f "$legacy_lock_file"
    fi
}

is_project_scoped_notification() {
    if [[ "${CODE_NOTIFY_SCOPE:-}" == "project" ]]; then
        return 0
    fi

    if [[ "$RAW_ARG1" != "codex" ]] && [[ -n "$RAW_ARG3" ]]; then
        return 0
    fi

    return 1
}

# Find the newest Codex state database without hard-coding a schema version suffix.
get_latest_codex_state_db() {
    local latest=""
    local candidate

    for candidate in "$HOME/.codex"/state*.sqlite; do
        [[ -e "$candidate" ]] || continue
        if [[ -z "$latest" ]] || [[ "$candidate" -nt "$latest" ]]; then
            latest="$candidate"
        fi
    done

    [[ -n "$latest" ]] || return 1
    printf '%s\n' "$latest"
}

# Resolve the thread originator from Codex local state when the notify payload includes thread-id.
get_codex_thread_originator() {
    local thread_id="$1"
    local state_db

    [[ -n "$thread_id" ]] || return 1
    has_python3 || return 1

    state_db=$(get_latest_codex_state_db) || return 1

    python3 - "$state_db" "$thread_id" <<'PY' 2>/dev/null
import json
import pathlib
import sqlite3
import sys

db_path = pathlib.Path(sys.argv[1])
thread_id = sys.argv[2]

try:
    with sqlite3.connect(db_path) as conn:
        cur = conn.cursor()
        cur.execute("select rollout_path from threads where id = ?", (thread_id,))
        row = cur.fetchone()
except Exception:
    row = None

if not row or not row[0]:
    raise SystemExit(0)

try:
    first_line = pathlib.Path(row[0]).read_text(encoding="utf-8", errors="ignore").splitlines()[0]
    payload = json.loads(first_line).get("payload", {})
    originator = payload.get("originator", "")
except Exception:
    originator = ""

if isinstance(originator, str):
    print(originator, end="")
PY
}

# Suppress only when this Codex event came from the desktop app itself.
# Set CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK=1 to disable (used in tests).
is_codex_desktop_trigger() {
    [[ "$TOOL_NAME" != "codex" ]] && return 1
    [[ "${CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK:-}" == "1" ]] && return 1

    local client
    client=$(json_extract_string "$HOOK_DATA" "client" | tr '[:upper:]' '[:lower:]')
    case "$client" in
        *app*|appserver)
            return 0
            ;;
    esac

    local thread_id originator
    thread_id=$(json_extract_string "$HOOK_DATA" "thread-id")
    [[ -n "$thread_id" ]] || return 1

    originator=$(get_codex_thread_originator "$thread_id")
    case "$originator" in
        "Codex Desktop")
            return 0
            ;;
    esac

    return 1
}

# Function to check if notification should be suppressed
should_suppress_notification() {
    # Check kill switch first - instant disable without restart
    if [[ -f "$HOME/.claude/notifications/disabled" ]] && ! is_project_scoped_notification; then
        return 0  # Suppress notification
    fi

    # Skip suppression checks for test notifications
    if [[ "$HOOK_TYPE" == "test" ]]; then
        return 1
    fi

    # Timed snooze silences everything, including approval prompts — unlike
    # automatic rate limiting it is an explicit user request for quiet.
    if snooze_is_active; then
        return 0
    fi

    # Suppress only when this Codex event originated from the desktop app.
    if is_codex_desktop_trigger; then
        return 0
    fi

    # Rate limit stop notifications to prevent spam from parallel sub-agents
    if [[ "$HOOK_TYPE" == "stop" ]]; then
        if is_rate_limited "last_stop_notification" "$STOP_RATE_LIMIT_SECONDS"; then
            return 0  # Suppress - too soon since last notification
        fi
    fi

    # Suppress repeated state-style notifications such as idle_prompt.
    # Uses NOTIFICATION_SUBTYPE computed once in the main flow.
    if [[ "$HOOK_TYPE" == "notification" ]]; then
        if should_rate_limit_notification_subtype "$NOTIFICATION_SUBTYPE"; then
            if is_rate_limited "$(get_notification_rate_limit_key "$NOTIFICATION_SUBTYPE")" "$NOTIFICATION_RATE_LIMIT_SECONDS"; then
                return 0
            fi
        fi
    fi

    if is_claude_event_hook; then
        if is_rate_limited "$(get_event_rate_limit_key)" "$EVENT_RATE_LIMIT_SECONDS"; then
            return 0
        fi
    fi

    # For Stop hooks: Check if stop_hook_active is true
    if [[ "$HOOK_TYPE" == "stop" ]] && [[ -n "$HOOK_DATA" ]]; then
        if echo "$HOOK_DATA" | grep -q '"stop_hook_active":\s*true' 2>/dev/null; then
            return 0
        fi
    fi

    # Check for auto-accept indicator
    if [[ "${CLAUDE_AUTO_ACCEPT:-}" == "true" ]]; then
        return 0
    fi

    if [[ -n "$HOOK_DATA" ]]; then
        if echo "$HOOK_DATA" | grep -q '"autoAccepted":\s*true' 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Classify the notification subtype once; both the suppression check and the
# rate-limit update below use it (classification spawns jq/python3, which is
# the dominant pre-banner cost).
NOTIFICATION_SUBTYPE=""
if [[ "$HOOK_TYPE" == "notification" ]]; then
    if [[ -n "$AGY_FORCED_SUBTYPE" ]]; then
        # Antigravity hooks carry no type tokens in the payload, so the
        # wrapper-declared subtype (e.g. permission_prompt) is authoritative.
        NOTIFICATION_SUBTYPE="$AGY_FORCED_SUBTYPE"
    else
        NOTIFICATION_SUBTYPE=$(get_notification_subtype)
    fi
fi

# Map the current event to the canonical key stored by `cn alerts persist add`.
get_persist_key() {
    case "$HOOK_TYPE" in
        "stop")
            printf '%s\n' "stop"
            ;;
        "notification")
            printf '%s\n' "$NOTIFICATION_SUBTYPE"
            ;;
        "PreToolUse")
            printf '%s\n' "ask_user"
            ;;
        "SubagentStart"|"SubagentStop"|"TeammateIdle"|"TaskCreated"|"TaskCompleted")
            printf '%s\n' "$HOOK_TYPE"
            ;;
        *)
            printf '%s\n' ""
            ;;
    esac
}

# Persistent ("sticky") delivery: classified once, used by the per-platform
# senders to keep the alert visible until dismissed or until persist-timeout.
PERSIST_ACTIVE=0
if persist_is_type_enabled "$(get_persist_key)"; then
    PERSIST_ACTIVE=1
fi

notification_is_persistent() {
    [[ "$PERSIST_ACTIVE" == "1" ]]
}

# The agent reached a terminal state (done, waiting for input, or failed):
# take the running marker off its window. This must precede the suppression
# check — a snoozed or rate-limited stop is still a stop, and leaving the
# marker (or spinner) up would show an agent working when none is. Mid-run
# events (SubagentStart/Stop, TaskCreated/Completed, TeammateIdle) don't stop
# it: the main agent is still going.
case "$HOOK_TYPE" in
    "notification")
        # Notifications represent a pause except auth_success, which reports a
        # completed authentication flow rather than a question the user must
        # answer. Preserve the pause so a subsequent tool lifecycle hook can
        # put the running indicator back immediately after the user responds.
        # Only answerable mid-turn dialogs watch pane activity for the answer
        # itself: an idle reminder means no turn is running, so activity after
        # it (clicking the toast, typing the next prompt) must not light the
        # spinner — UserPromptSubmit is its real resume signal.
        case "$NOTIFICATION_SUBTYPE" in
            "auth_success")
                tmux_running_stop 2>/dev/null || true
                ;;
            "permission_prompt"|"elicitation_dialog")
                tmux_running_pause_for_input watch 2>/dev/null || true
                ;;
            *)
                tmux_running_pause_for_input 2>/dev/null || true
                ;;
        esac
        ;;
    "PreToolUse")
        # The managed Claude AskUserQuestion hook uses this event. Once its
        # answer is supplied, PostToolUse (or the following PreToolUse) resumes
        # the same turn without a UserPromptSubmit event.
        tmux_running_pause_for_input 2>/dev/null || true
        ;;
    "stop"|"error"|"failed")
        if [[ "$AGY_STOP_FINAL_CLEANUP" != "1" ]]; then
            tmux_running_stop 2>/dev/null || true
        fi
        # Codex and Antigravity send nothing further once a turn ends —
        # there is no equivalent of Claude's native idle_prompt reminder —
        # so a completed window could sit unattended forever. Arm the tmux
        # idle watch: if the pane's content holds still for the idle window
        # after this completion, one synthetic idle_prompt fires through
        # this notifier. Agent gating (TMUX_IDLE_AGENTS), alert-type gating
        # and tmux availability all live inside the helper; outside tmux
        # this is a no-op. Deliberately before the suppression check below:
        # a rate-limited completion is still a completion the user has not
        # seen, and the nudge run self-gates on snooze/kill switch anyway.
        if [[ "$HOOK_TYPE" == "stop" ]]; then
            tmux_idle_watch_arm_current "$TOOL_NAME" "$PROJECT_NAME" 2>/dev/null || true
        fi
        ;;
esac

# Check if notification should be suppressed. "error" is included so that the
# kill switch (cn off) and snooze silence failure alerts too — they are still
# notifications and must honour an explicit request for quiet.
if [[ "$HOOK_TYPE" == "stop" ]] || [[ "$HOOK_TYPE" == "notification" ]] || [[ "$HOOK_TYPE" == "error" ]] || [[ "$HOOK_TYPE" == "PreToolUse" ]] || is_claude_event_hook; then
    if should_suppress_notification; then
        exit 0
    fi
fi

# Update rate limit timestamp for stop notifications
if [[ "$HOOK_TYPE" == "stop" ]]; then
    update_rate_limit "last_stop_notification"
elif [[ "$HOOK_TYPE" == "notification" ]]; then
    if should_rate_limit_notification_subtype "$NOTIFICATION_SUBTYPE"; then
        update_rate_limit "$(get_notification_rate_limit_key "$NOTIFICATION_SUBTYPE")"
    fi
elif is_claude_event_hook; then
    update_rate_limit "$(get_event_rate_limit_key)"
fi

choose_random_message() {
    local messages=("$@")
    local count="${#messages[@]}"

    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    printf '%s\n' "${messages[$((RANDOM % count))]}"
}

# Set notification parameters based on hook type and tool.
# BADGE_ICON marks the originating tmux window's name (see tmux_badge_set);
# events without one (usage alerts fire from the background watcher, not the
# user's pane) skip the badge.
BADGE_ICON=""
case "$HOOK_TYPE" in
    "stop")
        TITLE="$TOOL_DISPLAY 🟢"
        BADGE_ICON="🟢"
        SUBTITLE="Task Complete"
        MESSAGE=$(choose_random_message \
            "$TOOL_DISPLAY completed the task" \
            "$TOOL_DISPLAY finished the task" \
            "$TOOL_DISPLAY is done" \
            "$TOOL_DISPLAY wrapped up")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Glass"
        ;;
    "notification")
        TITLE="$TOOL_DISPLAY 💬"
        BADGE_ICON="💬"
        SUBTITLE="Input Required"
        SOUND="Ping"
        case "$NOTIFICATION_SUBTYPE" in
            "idle_prompt")
                # Idle is a nudge, not a question: distinct icon so a glance
                # tells "waiting on you" apart from an actual input request.
                TITLE="$TOOL_DISPLAY 🥱"
                BADGE_ICON="🥱"
                MESSAGE=$(choose_random_message \
                    "$TOOL_DISPLAY is idle" \
                    "$TOOL_DISPLAY is waiting" \
                    "$TOOL_DISPLAY is ready for you" \
                    "$TOOL_DISPLAY paused for input")
                ;;
            "permission_prompt")
                MESSAGE=$(choose_random_message \
                    "$TOOL_DISPLAY needs your approval" \
                    "$TOOL_DISPLAY is waiting for approval" \
                    "$TOOL_DISPLAY needs permission to continue" \
                    "$TOOL_DISPLAY has an approval request")
                ;;
            "elicitation_dialog")
                MESSAGE=$(choose_random_message \
                    "$TOOL_DISPLAY needs MCP tool input" \
                    "$TOOL_DISPLAY is waiting for MCP input" \
                    "$TOOL_DISPLAY needs a tool response" \
                    "$TOOL_DISPLAY has an MCP prompt")
                ;;
            "auth_success")
                SUBTITLE="Authentication"
                MESSAGE=$(choose_random_message \
                    "$TOOL_DISPLAY authentication succeeded" \
                    "$TOOL_DISPLAY signed in successfully" \
                    "$TOOL_DISPLAY authentication is complete" \
                    "$TOOL_DISPLAY is authenticated")
                ;;
            *)
                MESSAGE=$(choose_random_message \
                    "$TOOL_DISPLAY needs your input" \
                    "$TOOL_DISPLAY is waiting for you" \
                    "$TOOL_DISPLAY needs a response" \
                    "$TOOL_DISPLAY has something for you")
                ;;
        esac
        VOICE_MESSAGE="$MESSAGE"
        ;;
    "SubagentStart")
        TITLE="$TOOL_DISPLAY 🍃"
        BADGE_ICON="🍃"
        SUBTITLE="Subagent Started"
        MESSAGE=$(choose_random_message \
            "$TOOL_DISPLAY started a subagent" \
            "$TOOL_DISPLAY launched a subagent" \
            "$TOOL_DISPLAY delegated work to a subagent" \
            "$TOOL_DISPLAY spun up a subagent")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Pop"
        ;;
    "SubagentStop")
        TITLE="$TOOL_DISPLAY 🍂"
        BADGE_ICON="🍂"
        SUBTITLE="Subagent Complete"
        MESSAGE=$(choose_random_message \
            "$TOOL_DISPLAY subagent completed" \
            "$TOOL_DISPLAY subagent finished" \
            "$TOOL_DISPLAY subagent is done" \
            "$TOOL_DISPLAY subagent wrapped up")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Glass"
        ;;
    "TeammateIdle")
        TITLE="$TOOL_DISPLAY 💤"
        BADGE_ICON="💤"
        SUBTITLE="Teammate Idle"
        MESSAGE=$(choose_random_message \
            "$TOOL_DISPLAY teammate is waiting for input" \
            "$TOOL_DISPLAY teammate is idle" \
            "$TOOL_DISPLAY teammate needs your response" \
            "$TOOL_DISPLAY teammate paused for input")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Ping"
        ;;
    "TaskCreated")
        TITLE="$TOOL_DISPLAY 📙"
        BADGE_ICON="📙"
        SUBTITLE="Task Created"
        MESSAGE=$(choose_random_message \
            "$TOOL_DISPLAY agent-team task was created" \
            "$TOOL_DISPLAY created an agent-team task" \
            "$TOOL_DISPLAY added a team task" \
            "$TOOL_DISPLAY opened a new agent-team task")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Pop"
        ;;
    "TaskCompleted")
        TITLE="$TOOL_DISPLAY 🟢"
        BADGE_ICON="🟢"
        SUBTITLE="Task Complete"
        MESSAGE=$(choose_random_message \
            "$TOOL_DISPLAY agent-team task completed" \
            "$TOOL_DISPLAY completed a team task" \
            "$TOOL_DISPLAY finished an agent-team task" \
            "$TOOL_DISPLAY team task is done")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Glass"
        ;;
    "error"|"failed")
        TITLE="$TOOL_DISPLAY 🧨"
        BADGE_ICON="🧨"
        SUBTITLE="Error"
        MESSAGE=$(choose_random_message \
            "An error occurred in $TOOL_DISPLAY" \
            "$TOOL_DISPLAY hit an error" \
            "$TOOL_DISPLAY ran into a problem" \
            "$TOOL_DISPLAY reported a failure")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Basso"
        ;;
    "test")
        TITLE="Code-Notify Test 🧪"
        BADGE_ICON="🧪"
        SUBTITLE="$PROJECT_NAME"
        MESSAGE=$(choose_random_message \
            "Notifications are working!" \
            "Code-Notify is working!" \
            "Test notification delivered!" \
            "Notification delivery is working!")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Glass"
        ;;
    "usage")
        TITLE="${CODE_NOTIFY_USAGE_TITLE:-$TOOL_DISPLAY usage alert}"
        SUBTITLE="Usage Alert"
        MESSAGE="${CODE_NOTIFY_USAGE_MESSAGE:-$(choose_random_message \
            "$TOOL_DISPLAY usage changed" \
            "$TOOL_DISPLAY usage has an update" \
            "$TOOL_DISPLAY usage needs attention" \
            "$TOOL_DISPLAY usage crossed a threshold")}"
        VOICE_MESSAGE="${CODE_NOTIFY_USAGE_VOICE_MESSAGE:-$MESSAGE}"
        SOUND="Ping"
        ;;
    "usage_reset")
        TITLE="${CODE_NOTIFY_USAGE_TITLE:-$TOOL_DISPLAY tokens reset}"
        SUBTITLE="Tokens Reset"
        MESSAGE="${CODE_NOTIFY_USAGE_MESSAGE:-$(choose_random_message \
            "$TOOL_DISPLAY tokens have reset. Usage is back to 100%." \
            "$TOOL_DISPLAY token window reset" \
            "$TOOL_DISPLAY usage is back to full" \
            "$TOOL_DISPLAY tokens are available again")}"
        VOICE_MESSAGE="${CODE_NOTIFY_USAGE_VOICE_MESSAGE:-$MESSAGE}"
        SOUND="Hero"
        ;;
    "PreToolUse")
        # AskUserQuestion: extract question text and show notification
        ASK_QUESTION_TEXT=""
        if has_jq; then
            ASK_QUESTION_TEXT=$(printf '%s' "$HOOK_DATA" | jq -r '.tool_input.questions[0].question // ""' 2>/dev/null)
        elif has_python3; then
            ASK_QUESTION_TEXT=$(printf '%s' "$HOOK_DATA" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    questions = data.get("tool_input", {}).get("questions", [])
    print(questions[0]["question"] if questions else "", end="")
except Exception:
    print("", end="")
' 2>/dev/null)
        fi

        TITLE="$TOOL_DISPLAY 🙋"
        BADGE_ICON="🙋"
        SUBTITLE="Question"
        if [[ -n "$ASK_QUESTION_TEXT" ]]; then
            MESSAGE=$(printf '%s\n' "$ASK_QUESTION_TEXT" | head -c 150 | tr '\n' ' ')
            MESSAGE="${MESSAGE% }"
            if [[ ${#ASK_QUESTION_TEXT} -gt 150 ]]; then
                MESSAGE="${MESSAGE}..."
            fi
            VOICE_MESSAGE="$TOOL_DISPLAY is asking a question"
        else
            MESSAGE=$(choose_random_message \
                "$TOOL_DISPLAY is asking a question" \
                "$TOOL_DISPLAY has a question" \
                "$TOOL_DISPLAY needs an answer" \
                "$TOOL_DISPLAY is waiting on a question")
            VOICE_MESSAGE="$MESSAGE"
        fi
        SOUND="Ping"
        ;;
    *)
        TITLE="$TOOL_DISPLAY 📢"
        BADGE_ICON="📢"
        SUBTITLE="Status Update"
        MESSAGE=$(choose_random_message \
            "$TOOL_DISPLAY: $HOOK_TYPE" \
            "$TOOL_DISPLAY sent a status update" \
            "$TOOL_DISPLAY reported $HOOK_TYPE" \
            "$TOOL_DISPLAY has an update")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Pop"
        ;;
esac

# Add project name to subtitle if available
if [[ -n "$PROJECT_NAME" ]] && [[ "$HOOK_TYPE" != "test" ]]; then
    SUBTITLE="$SUBTITLE - $PROJECT_NAME"
fi

# Get terminal bundle ID for macOS activation
get_terminal_bundle_id() {
    click_through_resolve_activation_bundle_id
}

# Persistent alert via alerter (https://github.com/vjeantet/alerter).
# alerter blocks until the user interacts, so it runs detached and the
# click handler jumps back to the originating tmux pane.
send_macos_alerter_notification() {
    local focus_cmd="$1"
    local timeout_seconds="${2:-${CODE_NOTIFY_ALERTER_TIMEOUT:-600}}"
    local -a alerter_args=(
        --title "$TITLE"
        --subtitle "$SUBTITLE"
        --message "$MESSAGE"
        --group "code-notify-$TOOL_NAME-$PROJECT_NAME"
    )
    # Timeout 0 keeps the alert up until the user closes it (alerter waits
    # forever when no --timeout is given).
    if (( timeout_seconds > 0 )); then
        alerter_args+=(--timeout "$timeout_seconds")
    fi
    (
        # result stays scoped to this background subshell (the subshell body
        # is not a function, so `local` cannot be used here).
        result=$(alerter "${alerter_args[@]}" 2>/dev/null)
        case "$result" in
            "@CONTENTCLICKED"|"@ACTIONCLICKED")
                if [[ -n "$focus_cmd" ]]; then
                    /bin/sh -c "$focus_cmd" > /dev/null 2>&1
                fi
                ;;
        esac
    ) > /dev/null 2>&1 &
    disown 2>/dev/null || true
}

terminal_notifier_supports_focus() {
    terminal-notifier -help 2>&1 | grep -q -- "-focus"
}

# Function to send notification on macOS
send_macos_notification() {
    local bundle_id focus_cmd badge_clear_cmd
    bundle_id=$(get_terminal_bundle_id)

    # When running inside tmux, clicking the notification jumps back to the
    # originating tmux window/pane (in addition to activating the terminal).
    focus_cmd=$(tmux_focus_build_command "$bundle_id" 2>/dev/null) || focus_cmd=""

    # For glance-clear agents, clicking also clears the window-name badge.
    # Appended to focus_cmd so every click path (alerter, -execute) restores the
    # name; the clear command re-checks the saved state at click time, so it is a
    # no-op when no badge is set. Engage-clear agents (Claude, hooks-based Codex)
    # clear on prompt-submit instead, so a click there jumps to the window
    # without clearing — clicking is a glance.
    badge_clear_cmd=""
    if badge_glance_clear_enabled; then
        badge_clear_cmd=$(tmux_badge_build_clear_command 2>/dev/null) || badge_clear_cmd=""
    fi
    if [[ -n "$badge_clear_cmd" ]] && [[ -n "$focus_cmd" ]]; then
        focus_cmd="$focus_cmd; $badge_clear_cmd"
    fi

    if notification_is_persistent && command -v alerter &> /dev/null; then
        # Persistent alert: stays visible until clicked/closed or until the
        # persist timeout. Outside tmux, clicking still activates the
        # originating terminal app.
        if [[ -z "$focus_cmd" ]] && [[ -n "$bundle_id" ]]; then
            focus_cmd=$(printf 'open -b %q' "$bundle_id")
        fi
        send_macos_alerter_notification "$focus_cmd" "$(persist_get_timeout_seconds)"
    elif command -v terminal-notifier &> /dev/null; then
        # Keep desktop notifications silent and let play_sound() own audio playback.
        # That avoids double audio and preserves custom sound files.
        local tn_args=(
            -title "$TITLE"
            -subtitle "$SUBTITLE"
            -message "$MESSAGE"
            -group "code-notify-$TOOL_NAME-$PROJECT_NAME"
            -activate "$bundle_id"
        )
        # Show the originating tool's icon when known (claude/codex/gemini).
        if [[ -n "$TOOL_NAME" ]]; then
            tn_args+=(-appIcon "$TOOL_NAME")
        fi
        if terminal_notifier_supports_focus; then
            # -focus and -execute run together on click, so the badge clear
            # rides alongside the built-in focus handling.
            tn_args+=(-focus)
            if [[ -n "$badge_clear_cmd" ]]; then
                tn_args+=(-execute "$badge_clear_cmd")
            fi
        elif [[ -n "$focus_cmd" ]]; then
            tn_args+=(-execute "$focus_cmd")
        fi
        terminal-notifier "${tn_args[@]}" 2>/dev/null
    elif [[ -n "$focus_cmd" ]] && command -v alerter &> /dev/null; then
        send_macos_alerter_notification "$focus_cmd"
    else
        # osascript doesn't support click-to-activate, but we can use a workaround.
        # Keep this silent too so custom/default sound playback stays single-sourced.
        osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\" subtitle \"$SUBTITLE\"" 2>/dev/null
    fi
}

# Function to send notification on Linux
send_linux_notification() {
    if command -v notify-send &> /dev/null; then
        local -a ns_args=(
            --urgency=normal
            --app-name="Code-Notify"
            --icon=dialog-information
        )
        if notification_is_persistent; then
            # Critical urgency stays on screen in GNOME/KDE until dismissed;
            # expire-time is a best-effort cap (0 = never expire).
            ns_args=(
                --urgency=critical
                --app-name="Code-Notify"
                --icon=dialog-information
                --expire-time="$(( $(persist_get_timeout_seconds) * 1000 ))"
            )
        fi
        notify-send "$TITLE" "$MESSAGE" "${ns_args[@]}" 2>/dev/null
    elif command -v zenity &> /dev/null; then
        zenity --notification \
            --text="$TITLE\n$MESSAGE" \
            2>/dev/null
    else
        echo "[$TITLE] $MESSAGE" | wall 2>/dev/null
    fi
}

# Strip non-ASCII characters before sending toast text to wsl-notify-send.exe.
sanitize_wsl_text() {
    printf '%s' "$1" | LC_ALL=C sed 's/[^\x20-\x7E]//g; s/  */ /g; s/^ *//; s/ *$//'
}

# Function to send notification on Windows
send_windows_notification() {
    if command -v powershell &> /dev/null; then
        powershell -Command "
            if (Get-Module -ListAvailable -Name BurntToast) {
                New-BurntToastNotification -Text '$TITLE', '$MESSAGE'
            } else {
                Add-Type -AssemblyName System.Windows.Forms
                \$notification = New-Object System.Windows.Forms.NotifyIcon
                \$notification.Icon = [System.Drawing.SystemIcons]::Information
                \$notification.BalloonTipIcon = 'Info'
                \$notification.BalloonTipTitle = '$TITLE'
                \$notification.BalloonTipText = '$MESSAGE'
                \$notification.Visible = \$true
                \$notification.ShowBalloonTip(10000)
            }
        " 2>/dev/null
    elif command -v msg &> /dev/null; then
        msg "%USERNAME%" "$TITLE: $MESSAGE" 2>/dev/null
    fi
}

# Check if voice is enabled for this tool
should_speak() {
    if [[ "$HOOK_TYPE" == "usage_reset" && "${CODE_NOTIFY_USAGE_RESET_VOICE:-true}" == "true" ]]; then
        return 0
    fi

    # Check tool-specific voice setting first
    if [[ -n "$TOOL_NAME" ]]; then
        local tool_voice_file="$HOME/.claude/notifications/voice-$TOOL_NAME"
        if [[ -f "$tool_voice_file" ]]; then
            return 0
        fi
    fi

    # Fall back to global voice setting
    local global_voice_file="$HOME/.claude/notifications/voice-enabled"
    if [[ -f "$global_voice_file" ]]; then
        return 0
    fi

    return 1
}

# Get voice setting (tool-specific or global)
get_voice_setting() {
    if [[ "$HOOK_TYPE" == "usage_reset" ]]; then
        local usage_reset_voice
        usage_reset_voice=$(get_voice "tool" "$TOOL_NAME" 2>/dev/null || get_voice "global" 2>/dev/null || true)
        if [[ -n "$usage_reset_voice" ]]; then
            printf '%s\n' "$usage_reset_voice"
            return
        fi
        printf '%s\n' "Samantha"
        return
    fi

    # Check tool-specific voice first
    if [[ -n "$TOOL_NAME" ]]; then
        local tool_voice_file="$HOME/.claude/notifications/voice-$TOOL_NAME"
        if [[ -f "$tool_voice_file" ]]; then
            cat "$tool_voice_file"
            return
        fi
    fi

    # Fall back to global
    get_voice "global" 2>/dev/null || echo ""
}

# Check if sound should play
should_play_sound() {
    if [[ "$HOOK_TYPE" == "usage_reset" ]]; then
        [[ "${CODE_NOTIFY_USAGE_RESET_SOUND:-true}" == "true" ]]
        return $?
    fi
    is_sound_enabled
}

get_notification_sound_file() {
    if [[ "$HOOK_TYPE" == "usage_reset" ]]; then
        if [[ -n "${CODE_NOTIFY_USAGE_RESET_SOUND_FILE:-}" ]]; then
            printf '%s\n' "$CODE_NOTIFY_USAGE_RESET_SOUND_FILE"
            return
        fi
        case "$(detect_os 2>/dev/null || uname -s | tr '[:upper:]' '[:lower:]')" in
            "macos"|"Darwin"|"darwin")
                printf '%s\n' "/System/Library/Sounds/Hero.aiff"
                return
                ;;
        esac
    fi

    get_sound
}

# Badge the originating tmux window's name with the event icon so the alert
# stays visible in the status line. Clearing differs by agent (BADGE_CLEAR_MODE,
# recorded on the badge itself so the agent-blind sweep honours it):
#   - Glance-clear agents (legacy codex, gemini): sweep first so badges on
#     windows the user has since visited are restored before a new one lands,
#     and let badge-set arm the focus hook that clears on the next visit. On
#     macOS clicking the notification also clears; elsewhere only these paths
#     do (notify-send has no click hook).
#   - Engage-clear agents (claude, hooks-based codex, antigravity): clear on the
#     next work signal instead, so no sweep and no focus hook — the badge
#     persists until the user actually engages the window with new work, and
#     the sweep skips it even when another agent's activity triggers one.
if badge_glance_clear_enabled; then
    tmux_badge_sweep 2>/dev/null || true
fi
if [[ -n "$BADGE_ICON" ]]; then
    # Terminal events badge even the visible window — completion should be
    # glanceable everywhere — and applying there also replaces a stale
    # waiting badge whose turn the user just watched end (an approval
    # answered inline leaves one). Waiting and mid-run events keep the
    # default skip: an idle reminder must not wipe or restack a badge the
    # user has not engaged away yet. `cn badge-visible on` (or
    # CODE_NOTIFY_TMUX_BADGE_VISIBLE=true) lifts the skip so every event
    # badges the window, focused or not.
    BADGE_VISIBLE_ACTION="skip"
    case "$HOOK_TYPE" in
        "stop"|"error"|"failed")
            BADGE_VISIBLE_ACTION="apply"
            ;;
    esac
    if tmux_badge_visible_enabled; then
        BADGE_VISIBLE_ACTION="apply"
    fi
    tmux_badge_set "$BADGE_ICON" "$BADGE_CLEAR_MODE" "" "$BADGE_VISIBLE_ACTION" 2>/dev/null || true
fi

# Send notification based on OS
OS=$(detect_os)
case "$OS" in
    macos)
        send_macos_notification
        # Voice and sound run detached so the hook exits right after the
        # banner — `say` alone blocks for seconds. Sound goes first so the
        # short alert chime starts before speech; `play_sound` backgrounds
        # afplay, and the natural TTS startup delay (synthesis round-trip,
        # or `say` warm-up) means the chime is done before speech is audible.
        (
            # Sound notification first if enabled (separate from voice)
            if should_play_sound; then
                play_sound "$(get_notification_sound_file)"
            fi
            # Voice notification if enabled
            if should_speak; then
                VOICE=$(get_voice_setting)
                if [[ -n "$VOICE" ]]; then
                    speak_notification "$VOICE_MESSAGE" "$VOICE"
                fi
            fi
        ) > /dev/null 2>&1 &
        disown 2>/dev/null || true
        ;;
    linux)
        send_linux_notification
        # Sound notification if enabled
        if should_play_sound; then
            play_sound "$(get_notification_sound_file)"
        fi
        ;;
    wsl)
        # Send Windows toast notification via wsl-notify-send.exe
        # Windows requires toast notifications to use an AppUserModelID registered via a Start Menu
        # shortcut. Without a registered appId, toasts may not appear or only show in Action Center.
        # We borrow the terminal's appId since it's already registered and has banner permissions.
        if command -v wsl-notify-send.exe &> /dev/null; then
            WSL_APP_ID=""
            # Detect terminal app ID from environment
            if [[ "${WT_SESSION:-}" != "" ]]; then
                # Running inside Windows Terminal
                WSL_APP_ID="Microsoft.WindowsTerminal_8wekyb3d8bbwe!App"
            fi
            # Strip non-ASCII (emojis corrupt the XML toast template inside wsl-notify-send.exe)
            # wsl-notify-send.exe only accepts ONE positional arg; two args prints usage and exits
            WSL_TITLE=$(sanitize_wsl_text "$TITLE")
            WSL_MESSAGE=$(sanitize_wsl_text "$MESSAGE")
            # Add project name and branch to body
            WSL_BRANCH=$(sanitize_wsl_text "$(git -C "$PWD" branch --show-current 2>/dev/null || true)")
            WSL_PROJECT=$(sanitize_wsl_text "$PROJECT_NAME")
            if [[ -n "$WSL_BRANCH" ]]; then
                WSL_PROJECT="$WSL_PROJECT ($WSL_BRANCH)"
            fi
            WSL_NOTIFY_ARGS=(--appId "${WSL_APP_ID:-wsl-notify-send}" -c "$WSL_TITLE")
            WSL_BODY=$(printf '%s\n%s' "$WSL_PROJECT" "$WSL_MESSAGE")
            wsl-notify-send.exe "${WSL_NOTIFY_ARGS[@]}" "$WSL_BODY" 2>/dev/null
        else
            # Fallback to notify-send (only works if WSLg is active)
            send_linux_notification
        fi
        # Sound notification if enabled
        if should_play_sound; then
            play_sound "$(get_notification_sound_file)"
        fi
        ;;
    windows)
        send_windows_notification
        ;;
    *)
        echo "Unsupported OS: $OS" >&2
        exit 1
        ;;
esac

# Post-banner bookkeeping: channel delivery (logs/webhooks), the usage check,
# and the log line. The usage check makes a network curl (up to
# CODE_NOTIFY_USAGE_TIMEOUT_SECONDS, default 5s) and channel webhooks can also
# touch the network, so none of this should keep the hook process alive — while
# a Stop/Notification hook runs, Claude Code treats the session as still
# working, which is what made notifications feel seconds late.
run_post_banner_tail() {
    channels_deliver "$TITLE" "$MESSAGE" "$TOOL_NAME" "$PROJECT_NAME" "${CODE_NOTIFY_USAGE_CONTEXT:-}" || true

    if [[ "${CODE_NOTIFY_SKIP_USAGE_CHECK:-}" != "1" ]]; then
        case "$TOOL_NAME" in
            "codex"|"claude")
                usage_check_with_lock "$TOOL_NAME" >/dev/null 2>&1 || true
                ;;
        esac
    fi

    local log_dir="$HOME/.claude/logs"
    if [[ -d "$log_dir" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$TOOL_NAME] [$PROJECT_NAME] $MESSAGE" >> "$log_dir/notifications.log"
    fi
}

# Default: detach so the hook returns immediately. Tests set
# CODE_NOTIFY_TAIL_SYNC=1 to keep the tail synchronous (deterministic log/curl
# assertions and clean temp-dir teardown).
if [[ "${CODE_NOTIFY_TAIL_SYNC:-}" == "1" ]]; then
    run_post_banner_tail
else
    run_post_banner_tail > /dev/null 2>&1 &
    disown 2>/dev/null || true
fi

exit 0
