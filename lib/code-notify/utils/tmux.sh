#!/bin/bash

# tmux click-to-focus support for Code-Notify (macOS).
#
# When a notification originates from a process running inside a tmux pane
# (Claude Code, Codex, Gemini CLI hooks inherit TMUX/TMUX_PANE), these
# helpers build a shell command that jumps back to that exact pane when the
# user clicks the notification.
#
# The generated command runs from the notifier app's context (/bin/sh -c,
# minimal PATH, no attached tmux client), so it embeds the absolute tmux
# path, the server socket, and performs an explicit client lookup.

# Quote a value for safe single-quoted embedding in a shell command,
# escaping embedded single quotes: a'b -> 'a'\''b'
tmux_focus_shell_quote() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\\\'\'}"
}

# Whether the current process is running inside a usable tmux pane.
tmux_focus_available() {
    [[ -n "${TMUX:-}" ]] && [[ -n "${TMUX_PANE:-}" ]] && command -v tmux &> /dev/null
}

# Print "session_id window_id pane_id" for the current pane.
# Uses stable tmux IDs ($N @N %N) that survive window renumbering.
tmux_focus_capture_target() {
    if ! tmux_focus_available; then
        return 1
    fi
    tmux display-message -p -t "$TMUX_PANE" '#{session_id} #{window_id} #{pane_id}' 2>/dev/null
}

# Build the command a notifier should run on click to focus the originating
# tmux session/window/pane. Takes an optional macOS bundle ID to activate.
# Prints nothing and returns 1 when not running inside tmux.
tmux_focus_build_command() {
    local bundle_id="${1:-}"
    local target session_id window_id pane_id tmux_bin socket_path

    target=$(tmux_focus_capture_target) || return 1
    read -r session_id window_id pane_id <<< "$target"

    # Only stable tmux IDs get embedded in the command; reject anything else.
    # Patterns live in variables so the \$ escape survives both bash and zsh.
    local session_re='^\$[0-9]+$' window_re='^@[0-9]+$' pane_re='^%[0-9]+$'
    if [[ ! "$session_id" =~ $session_re ]] ||
        [[ ! "$window_id" =~ $window_re ]] ||
        [[ ! "$pane_id" =~ $pane_re ]]; then
        return 1
    fi

    tmux_bin=$(command -v tmux)
    socket_path="${TMUX%%,*}"
    if [[ -z "$tmux_bin" ]] || [[ -z "$socket_path" ]]; then
        return 1
    fi

    local q_tmux q_socket q_session q_window q_pane q_bundle
    q_tmux=$(tmux_focus_shell_quote "$tmux_bin")
    q_socket=$(tmux_focus_shell_quote "$socket_path")
    q_session=$(tmux_focus_shell_quote "$session_id")
    q_window=$(tmux_focus_shell_quote "$window_id")
    q_pane=$(tmux_focus_shell_quote "$pane_id")

    # t() wraps tmux with the captured socket. The client lookup prefers the
    # most recently active client attached to the target session, then falls
    # back to the most recently active client overall and switches it over.
    # Append system dirs so head/sort/cut/open resolve even under the
    # notifier app's minimal PATH; appending keeps any existing PATH first.
    local cmd
    cmd="PATH=\"\${PATH:-}:/usr/bin:/bin\"; export PATH; "
    cmd+="t() { $q_tmux -S $q_socket \"\$@\" 2>/dev/null; }; "
    cmd+="t select-window -t $q_window; "
    cmd+="t select-pane -t $q_pane; "
    cmd+="c=\$(t list-clients -t $q_session -F \"#{client_activity} #{client_name}\" | sort -rn | head -n 1 | cut -d \" \" -f 2-); "
    cmd+="if [ -z \"\$c\" ]; then c=\$(t list-clients -F \"#{client_activity} #{client_name}\" | sort -rn | head -n 1 | cut -d \" \" -f 2-); fi; "
    cmd+="if [ -n \"\$c\" ]; then t switch-client -c \"\$c\" -t $q_session; fi"

    if [[ -n "$bundle_id" ]]; then
        q_bundle=$(tmux_focus_shell_quote "$bundle_id")
        cmd+="; open -b $q_bundle"
    fi

    printf '%s' "$cmd"
}
