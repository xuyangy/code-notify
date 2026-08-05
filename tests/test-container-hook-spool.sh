#!/bin/bash

# The in-container hooks' spool naming, exercised as the agents actually use
# them.
#
# omp instantiates the hook factory once per session — primary AND every
# subagent — inside one process. Approval events are deliberately not gated to
# the primary session (a subagent's prompt occupies the same screen and needs
# you just as much), so subagent instances do emit. A per-instance sequence
# counter therefore restarts at 0 in each of them, and two instances emitting in
# the same millisecond would name the same file, the second rename destroying
# the first. Losing an approval request that way is the worst failure this
# project has, so the naming is pinned here.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/../lib/code-notify/hooks"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# The hooks are TypeScript. Node 23.6+ and Bun both run them directly; without
# either, skip rather than fail — the same way the PowerShell tests do.
RUNNER=""
RUNNER_ARGS=()
if command -v node > /dev/null 2>&1 && node -e 'process.exit(process.versions.node.split(".")[0] >= 24 ? 0 : 1)' 2>/dev/null; then
    RUNNER="node"
    # Type stripping and the typeless-package notice are both expected here.
    RUNNER_ARGS=(--no-warnings)
elif command -v bun > /dev/null 2>&1; then
    RUNNER="bun"
else
    echo "SKIP: neither node >= 24 nor bun is available to run the TypeScript hooks"
    exit 0
fi

TEST_ROOT="$(mktemp -d)"
cleanup() { rm -rf "$TEST_ROOT"; }
trap cleanup EXIT

HARNESS="$TEST_ROOT/harness.mjs"
cat > "$HARNESS" <<'HARNESS_EOF'
// Drives a hook the way its agent does: one factory call per session, several
// sessions in one process, then events fired back to back so they land in the
// same millisecond.
import { readdirSync } from "node:fs";

const [hookPath, spool, eventName] = process.argv.slice(2);

const mod = await import(hookPath);
const factory = mod.default;

const instance = () => {
    const handlers = new Map();
    factory({ on: (event, handler) => handlers.set(event, handler) });
    return handlers;
};

// Two sessions: the primary and a subagent, exactly as omp builds them.
const primary = instance();
const subagent = instance();

const ctx = { sessionManager: { getSessionId: () => "session-a" } };
const fire = async (handlers, id) => {
    const handler = handlers.get(eventName);
    if (!handler) throw new Error(`no handler registered for ${eventName}`);
    await handler({ toolName: "bash", source: "interactive" }, {
        sessionManager: { getSessionId: () => id },
    });
};

// Back to back, synchronously scheduled: same millisecond in practice.
await fire(primary, "session-a");
await fire(subagent, "session-b");

const files = readdirSync(spool).filter(name => name.endsWith(".ev"));
console.log(files.length);
HARNESS_EOF

run_case() {
    local agent="$1" event="$2" expected="$3" label="$4"
    local spool count
    spool="$TEST_ROOT/spool-$agent-$event"
    mkdir -p "$spool"

    count="$(CODE_NOTIFY_SPOOL="$spool" "$RUNNER" "${RUNNER_ARGS[@]}" "$HARNESS" \
        "$HOOKS_DIR/$agent/code-notify.ts" "$spool" "$event")" \
        || fail "$label — harness failed to run"

    [[ "$count" == "$expected" ]] \
        || fail "$label — expected $expected spool files, got $count (an event was overwritten)"
    pass "$label"
}

# omp: an approval request from two sessions in the same millisecond. Both must
# survive — this is the case that used to lose one silently.
run_case omp tool_approval_requested 2 \
    "omp keeps both approval requests when two sessions emit in the same millisecond"

# And the same invariant for the turn-scoped path, where both instances emit
# because each sees itself as primary until one claims the id.
run_case pi input 2 \
    "pi keeps both events when two hook instances emit in the same millisecond"

# How an omp turn settles, which the event alone does not say: omp reports an
# interrupt and an API failure through the same agent_end as a completion,
# carrying the outcome on the last assistant message. Reading it wrong announces
# "task complete" for a turn the user just killed with Escape.
OUTCOME="$TEST_ROOT/outcome.mjs"
cat > "$OUTCOME" <<'OUTCOME_EOF'
// One session, one agent_end, then the event names actually spooled.
import { readdirSync, readFileSync } from "node:fs";

const [hookPath, spool, payload] = process.argv.slice(2);

const mod = await import(hookPath);
const handlers = new Map();
mod.default({ on: (event, handler) => handlers.set(event, handler) });

await handlers.get("agent_end")(JSON.parse(payload), {
    sessionManager: { getSessionId: () => "session-a" },
});

const names = readdirSync(spool)
    .filter(name => name.endsWith(".ev"))
    .sort()
    .map(name => readFileSync(`${spool}/${name}`, "utf8").split("\t")[0]);
console.log(names.join(","));
OUTCOME_EOF

run_outcome() {
    local label="$1" expected="$2" payload="$3"
    local spool emitted
    spool="$TEST_ROOT/outcome-$(printf '%s' "$label" | tr -c '[:alnum:]' '-')"
    mkdir -p "$spool"

    emitted="$(CODE_NOTIFY_SPOOL="$spool" "$RUNNER" "${RUNNER_ARGS[@]}" "$OUTCOME" \
        "$HOOKS_DIR/omp/code-notify.ts" "$spool" "$payload")" \
        || fail "$label — harness failed to run"

    [[ "$emitted" == "$expected" ]] \
        || fail "$label — expected '$expected', got '$emitted'"
    pass "$label"
}

run_outcome "a finished turn emits stop" "stop" \
    '{"messages":[{"role":"assistant","stopReason":"stop"}]}'
# session_end is the relay's silent teardown: indicator down, nothing announced.
run_outcome "an interrupted turn announces nothing" "session_end" \
    '{"messages":[{"role":"assistant","stopReason":"aborted"}]}'
run_outcome "a failed turn emits stop_failure" "stop_failure" \
    '{"messages":[{"role":"assistant","stopReason":"error"}]}'
# The LAST assistant message decides, not the last message: omp appends its own
# continuity messages after an interrupted turn.
run_outcome "a trailing non-assistant message does not hide the interrupt" "session_end" \
    '{"messages":[{"role":"assistant","stopReason":"aborted"},{"role":"user"}]}'
# omp aborts its own stream to inject rules (TTSR self-repair) and schedules the
# retry itself — an internal continuation, not the turn ending.
run_outcome "an abort that will continue emits nothing" "" \
    '{"willContinue":true,"messages":[{"role":"assistant","stopReason":"aborted"}]}'
# Fails open: an unrecognised shape is a completion, because a missed completion
# is the failure this bridge exists to prevent.
run_outcome "an unrecognised settle still completes" "stop" '{}'

echo "All container hook spool tests passed"
