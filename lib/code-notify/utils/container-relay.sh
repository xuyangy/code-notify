#!/bin/bash

# Host-side relay for agents that run inside a container (pi, omp).
#
# pi and omp are launched through pi-less-yolo, which runs them in a Docker
# container. A hook inside that container cannot notify anything: it has no
# $TMUX, no access to the host tmux socket, and no notifier or notification
# binary. Its only channel back to the host is the agent state directory, which
# the launcher bind-mounts.
#
# So the in-container hook does the least it can — one small file per lifecycle
# event, dropped into a spool directory on that mount (see
# lib/code-notify/hooks/*/code-notify.ts) — and this relay turns those files
# into ordinary notifier invocations. The launcher starts it in the tmux pane
# the container renders into, so the notifier sees the same pane, window and
# TMUX_PANE any in-process hook would have seen, and every downstream feature
# (badge, spinner, click-to-focus, snooze, voice) works unchanged.
#
# Lifetime is the container session: the launcher starts one relay before
# `docker run` and stops it on exit, so nothing polls while no agent is running.

CONTAINER_RELAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Agents this relay serves. Anything else is rejected rather than passed to the
# notifier, which uses the name for badge, wording and rate-limit state.
CONTAINER_RELAY_AGENTS="pi|omp"

CONTAINER_RELAY_POLL_DEFAULT="0.2"

# Poll interval. The spool holds a handful of files per turn, so a tick is a
# glob and a stat of one small directory — the cost that matters is the
# wake-up itself, and 200ms of latency on an approval prompt is imperceptible.
#
# Validated rather than trusted, because the failure is silent and expensive: a
# `sleep` that rejects its argument returns immediately, and the loop's `|| true`
# (there so the launcher's SIGTERM does not look like an error) would turn that
# into an unthrottled spin for the whole session. Zero is rejected for the same
# reason — and because elsewhere in code-notify 0 means "disable" for a poll
# interval, so someone setting it that way expects less work, not a pegged core.
container_relay_poll_interval() {
    local requested="${CODE_NOTIFY_RELAY_POLL_SECONDS:-}"

    # A positive decimal: digits with an optional fractional part, and not zero.
    if [[ "$requested" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "$requested" =~ [1-9] ]]; then
        printf '%s' "$requested"
        return 0
    fi

    if [[ -n "$requested" ]]; then
        echo "code-notify relay: ignoring invalid CODE_NOTIFY_RELAY_POLL_SECONDS='$requested'," \
            "using ${CONTAINER_RELAY_POLL_DEFAULT}s" >&2
    fi
    printf '%s' "$CONTAINER_RELAY_POLL_DEFAULT"
}

CONTAINER_RELAY_POLL_SECONDS="$(container_relay_poll_interval)"

# The launcher session this relay belongs to: when that process is gone, the
# session is over. Validated for the same reason as the interval above — both
# ways of being wrong fail silently, in opposite directions:
#
#   - a non-numeric value makes `kill -0` fail, which the loop reads as "the
#     launcher exited" and stops on its first tick, costing the session every
#     notification without a word;
#   - zero makes `kill -0 0` address the caller's entire process group, which
#     essentially never fails, so the relay outlives the session it was started
#     for instead of ending with it.
#
# $PPID is the honest fallback: for a relay started by the launcher it IS the
# launcher, and for one started by hand it is the invoking shell.
container_relay_session_pid() {
    local requested="${CODE_NOTIFY_RELAY_SESSION_PID:-}"

    if [[ "$requested" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s' "$requested"
        return 0
    fi

    if [[ -n "$requested" ]]; then
        echo "code-notify relay: ignoring invalid CODE_NOTIFY_RELAY_SESSION_PID='$requested'," \
            "watching parent $PPID instead" >&2
    fi
    printf '%s' "$PPID"
}

CONTAINER_RELAY_SESSION_PID="$(container_relay_session_pid)"

# Tabs and newlines separate the record, so a field cannot contain them; the
# hook strips them already and this is the second line of defence. Control
# characters are dropped outright — these values reach a terminal notification.
container_relay_sanitize() {
    printf '%s' "$1" | tr -d '\000-\037' | cut -c1-512
}

# Resolve the notifier the same way an installed hook would, so a relay run
# from a checkout uses that checkout's notifier.
container_relay_notifier() {
    printf '%s' "${CODE_NOTIFY_NOTIFIER_PATH:-$CONTAINER_RELAY_DIR/../core/notifier.sh}"
}

# Resolve the project name for a spool record.
#
# Deliberately ignores the working directory the record carries. That value is
# named by the container — where the agent can write to the spool — and its only
# use here would be as the argument to `git -C`, running on the HOST with your
# privileges, in whatever directory it names.
#
# An earlier version tried to contain it with a string-prefix check against the
# launch directory. That is not containment: "$PWD/../elsewhere" carries the
# prefix, and so does any symlink the agent drops inside the mount (which is
# writable by design), and `git -C` follows both. Canonicalising both sides
# would close those two holes and leave a TOCTOU window behind them.
#
# The simpler observation is that the value buys nothing. This relay already
# runs in the directory the launcher mounted — that IS the project — and
# get_project_name_at resolves the git root from there. Input that is not
# needed does not get validated; it gets ignored.
container_relay_project() {
    get_project_name_at "$PWD"
}

# Turn one spool record into a notifier invocation.
#
# The agent name is passed through as the tool name, so pi and omp reach the
# notifier exactly as claude and codex do — including the argv shape, which is
# the contract the notifier's generic path already implements
# (notifier.sh <hook_type> <tool_name> [project_name]).
#
# Unknown events are ignored: a newer hook talking to an older relay must
# degrade to silence, never to a wrong notification.
container_relay_dispatch() {
    local agent="$1" event="$2"
    local notifier project
    notifier="$(container_relay_notifier)"
    [[ -f "$notifier" ]] || return 0

    project="$(container_relay_project)"

    # Exported for the notifier's tmux helpers: the container's agent process
    # is not an ancestor of this relay, so the usual ancestor walk cannot find
    # it. The launcher's PID stands in — when the launcher is gone the session
    # is over, which is exactly what the exit sweep needs to know.
    #
    # The validated value, not the raw variable: the sweep also tests it with
    # `kill -0`, so a 0 here would read as an agent that never exits and strand
    # the badge and spinner it is supposed to clean up.
    export CODE_NOTIFY_TMUX_AGENT_PID="$CONTAINER_RELAY_SESSION_PID"

    # Every invocation is || true: a notifier that fails must not end the
    # relay, or one bad event would silence the rest of the session.
    case "$event" in
        prompt_submit)
            CONTAINER_RELAY_TURN_ACTIVE=1
            bash "$notifier" UserPromptSubmit "$agent" "$project" < /dev/null > /dev/null 2>&1 || true
            ;;
        permission_request)
            printf '%s' '{"type":"permission_prompt"}' |
                bash "$notifier" notification "$agent" "$project" > /dev/null 2>&1 || true
            ;;
        question_asked)
            printf '%s' '{"type":"elicitation_dialog"}' |
                bash "$notifier" notification "$agent" "$project" > /dev/null 2>&1 || true
            ;;
        permission_replied)
            bash "$notifier" ResumeAfterInput "$agent" "$project" < /dev/null > /dev/null 2>&1 || true
            ;;
        stop)
            CONTAINER_RELAY_TURN_ACTIVE=0
            bash "$notifier" stop "$agent" "$project" < /dev/null > /dev/null 2>&1 || true
            ;;
        stop_failure)
            # Not turn-inactive: a usage limit ends the turn without ending the
            # work, and the notifier deliberately pauses rather than stops.
            bash "$notifier" StopFailure "$agent" "$project" < /dev/null > /dev/null 2>&1 || true
            ;;
        session_end)
            # The agent left mid-turn, or a turn was interrupted: silent
            # teardown, no notification of any kind.
            container_relay_teardown
            ;;
    esac
    return 0
}

# Whether a turn is in flight, so shutdown can tell "the user quit mid-turn"
# from "the turn ended and then the user quit". Only the first case has state
# left to clean up.
CONTAINER_RELAY_TURN_ACTIVE=0

# Retire the running indicator without notifying. Used when the agent exits
# (/exit, Ctrl-C, container death) or a turn is interrupted rather than
# finishing: there is no completion to announce, but a spinner left running
# would outlive the turn.
# tmux_running_stop is exactly that teardown — the notifier's stop path calls
# it first and delivers the toast separately.
#
# Skipped when no turn is in flight, because it is not free: it also disarms
# the settle and idle watches, which a just-delivered completion may have armed.
container_relay_teardown() {
    (( CONTAINER_RELAY_TURN_ACTIVE )) || return 0
    CONTAINER_RELAY_TURN_ACTIVE=0
    tmux_focus_available 2>/dev/null || return 0
    tmux_running_stop 2>/dev/null || true
    return 0
}

# Consume one spool file. The file is removed before dispatch so a notifier
# that hangs cannot cause the same event to be replayed on the next tick.
container_relay_consume() {
    local agent="$1" file="$2"
    local record event cwd tool_name

    record="$(head -n1 "$file" 2>/dev/null)"
    rm -f "$file" 2>/dev/null
    [[ -n "$record" ]] || return 0

    # The record's other two fields are split off but deliberately go no
    # further, so only the event is worth sanitizing (three processes a field,
    # on a path that runs for every event of every turn):
    #
    #   - cwd is named by the container and would only ever be an argument to
    #     `git -C` on the host — see container_relay_project for why that value
    #     is ignored rather than validated;
    #   - tool_name has nowhere to go. The notifier's approval wording is
    #     agent-scoped ("omp needs your approval") for every agent, including
    #     Claude, whose own hook payload carries the name too. Naming the tool
    #     would be a notifier feature, not a relay one.
    #
    # Both stay in the wire format so an older relay and a newer hook keep
    # understanding each other, and `read` still has to consume them or a
    # trailing field would land in the one value that IS used.
    # shellcheck disable=SC2034  # cwd and tool_name are split off, not used
    IFS=$'\t' read -r event cwd tool_name <<< "$record"
    event="$(container_relay_sanitize "${event:-}")"

    # Event names are an internal vocabulary: reject anything that is not one.
    [[ "$event" =~ ^[a-z_]+$ ]] || return 0

    container_relay_dispatch "$agent" "$event"
}

# Process everything currently spooled, in filename order — which the hook
# makes chronological — and one at a time: the notifier drives a state machine
# (running → paused → resumed) where the order is the meaning, so overlapping
# two events to shave latency would be a correctness bug, not an optimisation.
container_relay_drain() {
    local agent="$1" spool="$2"
    local file
    local -a pending

    pending=("$spool"/*.ev)
    for file in "${pending[@]}"; do
        container_relay_consume "$agent" "$file"
    done
    return 0
}

# Poll until the launcher exits, the spool directory disappears, or a signal
# asks us to stop.
container_relay_run() {
    local agent="$1" spool="$2"
    local parent="$CONTAINER_RELAY_SESSION_PID"

    [[ "$agent" =~ ^($CONTAINER_RELAY_AGENTS)$ ]] || {
        echo "code-notify relay: unsupported agent '$agent'" >&2
        return 1
    }
    [[ -n "$spool" ]] || {
        echo "code-notify relay: no spool directory given" >&2
        return 1
    }

    mkdir -p "$spool" 2>/dev/null || return 1

    shopt -s nullglob
    while :; do
        container_relay_drain "$agent" "$spool"

        (( CONTAINER_RELAY_STOPPING )) && break
        # Both liveness checks, because either can be the one that fails: the
        # launcher removes the spool on a clean exit, and a launcher killed
        # with SIGKILL removes nothing at all.
        [[ -d "$spool" ]] || break
        kill -0 "$parent" 2>/dev/null || break

        # Interrupted by the launcher's SIGTERM, which is not a failure.
        sleep "$CONTAINER_RELAY_POLL_SECONDS" || true
    done

    container_relay_drain "$agent" "$spool"
    container_relay_teardown
    return 0
}

# Entry point for `code-notify relay <agent> <spool-dir>`.
handle_relay_command() {
    local agent="${1:-}" spool="${2:-}"

    # The caller (bin/code-notify) runs under `set -e`, which is the wrong mode
    # for a loop whose whole job is to survive individual failures for the
    # length of a session.
    set +e

    # Claimed before anything slow, because until it is, SIGTERM is simply
    # fatal — and the launcher's kill arrives as soon as `docker run` returns.
    #
    # A signal must not exit the loop where it lands: the container writes its
    # last events (the turn's completion) milliseconds before it exits, so
    # exiting on the signal itself would drop exactly the notification the user
    # was waiting for. The handler only asks the loop to stop; every exit path
    # drains the spool one final time.
    CONTAINER_RELAY_STOPPING=0
    trap 'CONTAINER_RELAY_STOPPING=1' TERM INT HUP

    # Outside tmux there is no pane to badge and no spinner to run; the toast
    # would still fire, so the relay is still worth running.
    source "$CONTAINER_RELAY_DIR/detect.sh"
    source "$CONTAINER_RELAY_DIR/tmux.sh"

    container_relay_run "$agent" "$spool"
}
