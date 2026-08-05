#!/bin/bash

# Spoken tool names: the banner keeps the terse "omp", speech says "oh-my-pi".
# The rewrite must be whole-word — "omp" is also a substring of "completed",
# which appears in the very pools these events pick from.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
NOTIFIER="$ROOT_DIR/lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

os_name="$(uname -s)"
case "$os_name" in
    Darwin|Linux) ;;
    *)
        echo "SKIP: unsupported OS for voice tool name test"
        exit 0
        ;;
esac

# Speech is wired up on macOS only (see the `macos)` branch of notifier.sh's
# OS case statement); elsewhere the banner assertions still apply.
can_speak=false
[[ "$os_name" == "Darwin" ]] && can_speak=true

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
banner_log="$test_dir/banner.log"
say_log="$test_dir/say.log"
mkdir -p "$HOME/.claude/notifications" "$HOME/.claude/logs" "$fake_bin"

if [[ "$os_name" == "Darwin" ]]; then
    cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "-help" ]]; then exit 0; fi
printf '%s\n' "\$*" >> "$banner_log"
EOF
else
    cat > "$fake_bin/notify-send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$banner_log"
EOF
fi
cat > "$fake_bin/say" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$say_log"
EOF
chmod +x "$fake_bin"/*
fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

# The voice file both enables speech for the tool and names the `say` voice.
printf 'TestVoice\n' > "$HOME/.claude/notifications/voice-omp"
printf 'TestVoice\n' > "$HOME/.claude/notifications/voice-claude"

# Speech is spoken from a detached process; wait for it before asserting.
wait_for_say() {
    for _ in $(seq 1 200); do
        [[ -s "$say_log" ]] && return 0
        sleep 0.05
    done
    fail "timed out waiting for spoken output"
}

run_stop() {
    local tool="$1"
    : > "$banner_log"
    : > "$say_log"
    # Each run must notify: drop the rate-limit state from the previous one.
    rm -rf "$HOME/.claude/notifications/state"
    printf '{}' | PATH="$fake_path" bash "$NOTIFIER" stop "$tool" voice-name-test
    if "$can_speak"; then wait_for_say; fi
}

# --- omp: banner terse, speech pronounceable ---
run_stop omp
grep -q 'omp' "$banner_log" || fail "banner should keep the terse omp name"
grep -q 'oh-my-pi' "$banner_log" && fail "banner must not use the spoken name"
if "$can_speak"; then
    grep -q 'oh-my-pi' "$say_log" || fail "voice should speak oh-my-pi"
    grep -Eq '(^| )omp( |$)' "$say_log" && fail "voice must not speak the terse name"
    # The rewrite is whole-word: "completed"/"complete" must survive intact.
    grep -q 'oh-my-pi' "$say_log" && grep -q 'coh-my-pi' "$say_log" &&
        fail "rewrite mangled a word containing the tool name"
fi

# --- other tools are untouched ---
run_stop claude
grep -q 'Claude' "$banner_log" || fail "banner should name Claude"
if "$can_speak"; then
    grep -q 'Claude' "$say_log" || fail "voice should name Claude"
    grep -q 'oh-my-pi' "$say_log" && fail "Claude speech must not be rewritten"
fi

pass "voice tool name"
