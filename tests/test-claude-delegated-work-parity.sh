#!/bin/bash

# get_claude_delegated_work_state has a jq implementation and a python3
# fallback, and the two must classify every valid-JSON payload shape
# identically: one backend
# answering "clear" where the other answers "unknown" is the difference between
# delivering a completion and holding it back for the marker TTL. The full
# notifier only exercises whichever backend the host happens to have, so the
# function is extracted and run against both with the interpreter checks
# stubbed out.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
NOTIFIER="$ROOT_DIR/lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

for name in has_jq has_python3 get_claude_delegated_work_state; do
    fn="$(sed -n "/^${name}()/,/^}/p" "$NOTIFIER")"
    [[ -n "$fn" ]] || fail "could not extract $name from notifier.sh"
    eval "$fn"
done

have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1
command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the fallback backend"

state_with_backend() {
    local backend="$1" payload="$2"

    # A subshell per call so the stubs cannot leak between backends.
    (
        case "$backend" in
            jq) has_python3() { return 1; } ;;
            python3) has_jq() { return 1; } ;;
        esac
        # shellcheck disable=SC2034  # read by the eval'd classifier
        HOOK_DATA="$payload"
        get_claude_delegated_work_state
    )
}

# Each case asserts the expected classification AND that both backends agree on
# it. Malformed entries are the interesting half: they must not poison the scan.
check() {
    local desc="$1" payload="$2" expected="$3"
    local got_py got_jq

    got_py="$(state_with_backend python3 "$payload")"
    [[ "$got_py" == "$expected" ]] ||
        fail "$desc: python3 backend returned '$got_py', expected '$expected'"

    if (( have_jq )); then
        got_jq="$(state_with_backend jq "$payload")"
        [[ "$got_jq" == "$expected" ]] ||
            fail "$desc: jq backend returned '$got_jq', expected '$expected'"
    fi

    pass "$desc"
}

# Well-formed payloads.
check "running workflow" \
    '{"background_tasks":[{"id":"wf","type":"workflow","status":"running"}]}' "running"
check "pending subagent" \
    '{"background_tasks":[{"id":"a","type":"subagent","status":"pending"}]}' "running"
check "running cloud session" \
    '{"background_tasks":[{"id":"c","type":"cloud session","status":"running"}]}' "running"
check "running teammate alone" \
    '{"background_tasks":[{"id":"t","type":"teammate","status":"running"}]}' "teammate-only"
check "running shell only" \
    '{"background_tasks":[{"id":"s","type":"shell","status":"running"}]}' "clear"
check "empty registry" '{"background_tasks":[]}' "clear"
# The authoritative types win over teammate, so the newly added workflow must
# take precedence rather than reporting teammate-only.
check "running workflow beside a running teammate" \
    '{"background_tasks":[{"id":"w","type":"workflow","status":"running"},{"id":"t","type":"teammate","status":"running"}]}' \
    "running"
check "absent registry" '{"session_id":"s"}' "unknown"
check "registry is not an array" '{"background_tasks":{"id":"wf"}}' "unknown"

# Malformed entries: ignored, never fatal, and never a different answer per
# backend. Before element-level validation, a bare string made jq fail into
# "unknown" while python3 skipped it into "clear", and a list-valued type did
# the reverse.
check "bare string entry" '{"background_tasks":["oops"]}' "clear"
check "null entry" '{"background_tasks":[null]}' "clear"
check "numeric entry" '{"background_tasks":[42]}' "clear"
check "list-valued type" '{"background_tasks":[{"type":[],"status":"running"}]}' "clear"
check "object-valued status" '{"background_tasks":[{"type":"workflow","status":{}}]}' "clear"
check "missing type and status" '{"background_tasks":[{"id":"wf"}]}' "clear"
# Lenient policy stated explicitly: a delegate type with no status is not
# evidence of running work.
check "delegate type with absent status" \
    '{"background_tasks":[{"id":"wf","type":"workflow"}]}' "clear"
check "malformed entry beside a running workflow" \
    '{"background_tasks":["oops",{"id":"wf","type":"workflow","status":"running"}]}' "running"
check "malformed entry beside a running teammate" \
    '{"background_tasks":[{"type":[],"status":"running"},{"id":"t","type":"teammate","status":"running"}]}' \
    "teammate-only"

# Whole-payload corruption stays "unknown" so the caller preserves an existing
# marker instead of guessing from an unverified snapshot.
check "invalid json" 'not json at all' "unknown"
check "root null" 'null' "unknown"
check "root array" '[]' "unknown"

if (( have_jq )); then
    pass "jq and python3 backends agree on every case"
else
    echo "SKIP: jq not installed; only the python3 backend was exercised"
fi
