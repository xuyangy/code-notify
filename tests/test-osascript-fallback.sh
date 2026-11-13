#!/bin/bash

# The macOS osascript fallback (no terminal-notifier, no alerter) must deliver
# a message containing double quotes, backslashes or a leading "-" intact. The
# text has to travel as script arguments after `--`: interpolated into the
# AppleScript source, a quote ends the string early and the notification is
# lost (or the rest runs as AppleScript); without `--`, a message starting
# with "-e" is parsed as more script source.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="$SCRIPT_DIR/../lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "SKIP: macOS-specific osascript fallback test"
    exit 0
fi

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR/home"
fake_bin="$TEST_DIR/bin"
log_file="$TEST_DIR/osascript.args"
mkdir -p "$HOME/.claude/notifications" "$fake_bin"

# Records each argument NUL-terminated so embedded quotes survive for the
# assertions below. No real notification is shown.
cat > "$fake_bin/osascript" <<EOF
#!/bin/bash
printf '%s\0' "\$@" > "$log_file"
EOF
chmod +x "$fake_bin/osascript"

# $1: the question as the user should see it. $2: the same text JSON-escaped.
run_case() {
    local label="$1" question="$2" json_question="$3"
    local payload arg i boundary=-1
    local -a args=() script_lines=() values=()

    rm -f "$log_file"
    payload=$(printf '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"%s"}]}}' \
        "$json_question")
    printf '%s\n' "$payload" | env -u TMUX -u TMUX_PANE \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        CODE_NOTIFY_TAIL_SYNC=1 \
        bash "$NOTIFIER" PreToolUse claude test-project

    [[ -f "$log_file" ]] || fail "$label: osascript fallback did not run"
    while IFS= read -r -d '' arg; do
        args+=("$arg")
    done < "$log_file"

    # Options first: only -e <source> pairs, then the `--` boundary, then
    # exactly the three values.
    i=0
    while (( i < ${#args[@]} )); do
        if [[ "${args[$i]}" == "--" ]]; then
            boundary=$i
            break
        fi
        [[ "${args[$i]}" == "-e" ]] || fail "$label: unexpected osascript option '${args[$i]}' before --"
        script_lines+=("${args[$((i + 1))]}")
        i=$((i + 2))
    done
    (( boundary >= 0 )) || fail "$label: no -- before the message arguments"
    values=("${args[@]:$((boundary + 1))}")
    [[ ${#values[@]} -eq 3 ]] || fail "$label: expected message, title and subtitle after --, got ${#values[@]} values"

    for arg in "${script_lines[@]}"; do
        [[ "$arg" != *"$question"* ]] || fail "$label: message text was interpolated into the AppleScript source"
    done
    [[ "${values[0]}" == *"$question"* ]] || fail "$label: message was not passed intact: ${values[0]}"

    # Real osascript, same argv boundary, with a return handler instead of
    # display notification: it must hand back the message unchanged. Nothing
    # is displayed.
    local echoed
    echoed=$(/usr/bin/osascript -e 'on run argv' -e 'return item 1 of argv' -e 'end run' -- "${values[@]}") \
        || fail "$label: osascript rejected the argument list"
    [[ "$echoed" == "${values[0]}" ]] || fail "$label: osascript changed the message: $echoed"

    pass "$label"
}

run_case "message with quotes and backslashes is passed as an argument" \
    'Use "prod" or "staging" \ for C:\temp?' \
    'Use \"prod\" or \"staging\" \\ for C:\\temp?'
run_case "message starting with -e is passed as an argument" \
    '-e do shell script "touch /tmp/x"' \
    '-e do shell script \"touch /tmp/x\"'

# The script itself must still be valid AppleScript. osacompile only
# compiles, so nothing is displayed.
if [[ -x /usr/bin/osacompile ]]; then
    compile_args=()
    while IFS= read -r -d '' arg; do
        [[ "$arg" == "--" ]] && break
        compile_args+=("$arg")
    done < "$log_file"
    /usr/bin/osacompile -o "$TEST_DIR/fallback.scpt" "${compile_args[@]}" 2>"$TEST_DIR/compile.err" \
        || fail "fallback AppleScript does not compile: $(cat "$TEST_DIR/compile.err")"
    pass "fallback AppleScript compiles"
fi
