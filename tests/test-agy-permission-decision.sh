#!/bin/bash

# agy's PreToolUse payload carries no approval flag — every run_command looks
# identical — so the "input needed" banner is gated on whether agy will
# actually pause, reconstructed from its own permission lists. This exercises
# agy_permission_decision / agy_command_approval_kind directly (extracted from
# notifier.sh) against a fixture settings.json, on the jq path, the python3
# path, and the no-parser fallback. Precedence is deny > ask > allow, an
# unlisted command defaults to a prompt, and command(<prefix>) matches on whole
# leading words. The approval kind additionally separates a command an explicit
# ask rule covers from one no rule decides.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
NOTIFIER="$ROOT_DIR/lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

for name in has_jq has_python3 agy_permissions_file agy_normalize_command_line agy_permission_decision agy_command_approval_kind; do
    fn="$(sed -n "/^$name()/,/^}/p" "$NOTIFIER")"
    [[ -n "$fn" ]] || fail "could not extract $name from notifier.sh"
    eval "$fn"
done

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

cat > "$test_dir/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["command(git)", "command(ls)", "command(grep)"],
    "ask": ["command(git add)", "command(git commit)"],
    "deny": ["command(git push)"]
  }
}
EOF
export CODE_NOTIFY_AGY_SETTINGS="$test_dir/settings.json"

# decision: assert agy_permission_decision.
decision() {
    local desc="$1" cmd="$2" expected="$3" got
    got="$(agy_permission_decision "$cmd")"
    [[ "$got" == "$expected" ]] || fail "$desc (expected '$expected', got '$got')"
    pass "$desc"
}

# approval: assert whether agy_command_approval_kind predicts a pause at all
# (any kind but "none" -> notify, "none" -> suppress).
approval() {
    local desc="$1" cmd="$2" expected="$3" got="suppress"
    [[ "$(agy_command_approval_kind "$cmd")" != "none" ]] && got="notify"
    [[ "$got" == "$expected" ]] || fail "$desc (expected '$expected', got '$got')"
    pass "$desc"
}

# kind: assert agy_command_approval_kind itself.
kind() {
    local desc="$1" cmd="$2" expected="$3" got
    got="$(agy_command_approval_kind "$cmd")"
    [[ "$got" == "$expected" ]] || fail "$desc (expected '$expected', got '$got')"
    pass "$desc"
}

run_suite() {
    local label="$1"
    decision "$label: allowlisted git auto-runs" "git status" "auto"
    decision "$label: quoted allowlisted git auto-runs" '"git diff"' "auto"
    decision "$label: allowlisted ls auto-runs" "ls -la" "auto"
    decision "$label: ask entry beats allow (git add)" "git add -p" "ask"
    decision "$label: ask entry beats allow (git commit)" "git commit -m x" "ask"
    decision "$label: quoted ask entry beats allow" '"git add -p"' "ask"
    decision "$label: deny beats ask and allow (git push)" "git push origin main" "auto"
    decision "$label: unlisted command defaults to prompt" "python3 x.py" "ask"
    decision "$label: prefix is word-aware (gitfoo != git)" "gitfoo status" "ask"
    decision "$label: empty command prompts" "" "ask"
}

# --- jq path (real jq, if present) ---
if command -v jq >/dev/null 2>&1; then
    run_suite "jq"
else
    echo "SKIP: jq not installed, jq path not exercised"
fi

# --- python3 path (force jq off) ---
if command -v python3 >/dev/null 2>&1; then
    has_jq() { return 1; }
    run_suite "python3"
    # Restore jq detection for the remaining checks.
    eval "$(sed -n '/^has_jq()/,/^}/p' "$NOTIFIER")"
else
    echo "SKIP: python3 not installed, python3 path not exercised"
fi

# --- no-parser fallback: never suppress blindly ---
(
    has_jq() { return 1; }
    has_python3() { return 1; }
    [[ "$(agy_permission_decision "git status")" == "ask" ]] \
        || fail "no-parser fallback should default to ask"
)
pass "no-parser fallback defaults to ask"

# --- missing settings file: default to prompt ---
(
    export CODE_NOTIFY_AGY_SETTINGS="$test_dir/does-not-exist.json"
    [[ "$(agy_permission_decision "git status")" == "ask" ]] \
        || fail "missing settings should default to ask"
)
pass "missing settings defaults to ask"

# --- shell chaining / redirection always notifies (never swallow a prompt) ---
approval "pipe forces notify" "git status | head" "notify"
approval "&& chain forces notify" "git status && rm x" "notify"
approval "quoted && chain forces notify" '"git status && rm x"' "notify"
approval "redirect forces notify" "git status > out.txt" "notify"
# shellcheck disable=SC2016  # literal command text under test, not shell expansion
approval "command substitution forces notify" 'echo $(rm x)' "notify"
# shellcheck disable=SC2016  # literal command text under test, not shell expansion
approval "backtick forces notify" 'echo `rm x`' "notify"

# --- simple commands map through to the decision ---
approval "allowlisted command suppresses" "git status" "suppress"
approval "quoted allowlisted command suppresses" '"git diff"' "suppress"
# agy strips exactly one wrapper pair, so a self-quoted inner command stays
# quoted, matches nothing, and prompts — we must notify, not double-strip.
approval "double-quoted command notifies" '""git diff""' "notify"
approval "ask command notifies" "git add -p" "notify"
approval "unlisted command notifies" "python3 x.py" "notify"
approval "empty command notifies" "" "notify"

# Only an explicit ask rule is a firm prediction; everything no rule decides —
# chained commands included, whatever their leading command — is "unlisted".
kind "allowlisted command is none" "git status" "none"
kind "denied command is none" "git push origin" "none"
kind "explicit ask rule is ask" "git commit -m x" "ask"
kind "quoted explicit ask rule is ask" '"git add -p"' "ask"
kind "unlisted command is unlisted" "python3 x.py" "unlisted"
kind "chained allowlisted command is unlisted" "git status | head" "unlisted"
kind "chained denied command is unlisted" "git push && echo done" "unlisted"
kind "chained ask command stays ask" "git commit -m x && git push" "ask"
kind "empty command is ask" "" "ask"
[[ "$(agy_permission_decision "python3 x.py" unlisted)" == "unlisted" ]] \
    || fail "the default word should replace ask for an unlisted command"
[[ "$(agy_permission_decision "git add -p" unlisted)" == "ask" ]] \
    || fail "the default word must not replace an explicit ask rule"
pass "decision default word applies to unlisted commands only"

echo "All agy permission-decision tests passed"
