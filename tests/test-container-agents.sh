#!/bin/bash

# Containerized agents (pi, omp): hook install/removal and status reporting.
#
# Two regressions this pins down, both of which point `cn` at the wrong thing
# while looking like it worked:
#   - packing source and target into one whitespace-delimited line, which
#     truncates every path once $HOME contains a space;
#   - detecting the launcher relay by grepping the whole pi-less-yolo tasks
#     tree, which lets one agent's wiring (or a mere comment) make the other
#     agent claim a relay it does not have.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

load_lib() {
    # shellcheck source=/dev/null
    source "$LIB_DIR/utils/colors.sh"
    # shellcheck source=/dev/null
    source "$LIB_DIR/utils/detect.sh"
    # shellcheck source=/dev/null
    source "$LIB_DIR/core/config.sh"
}

run_spaced_path_test() {
    local base root install
    base="$(mktemp -d)"
    root="$base/dir with spaces"
    # BOTH sides must contain a space. A packed "<source> <target>" line
    # re-read positionally still yields a correct target — `read` gives the
    # last variable the whole remainder, spaces included — so only a spaced
    # INSTALL path exposes the truncation. Staging the library under one is
    # what makes this test able to fail.
    install="$base/code notify install"
    mkdir -p "$root" "$install"
    cp -R "$SCRIPT_DIR/../lib" "$install/lib"

    (
        export HOME="$root"
        export CODE_NOTIFY_PI_STATE_DIR="$root/.pi/agent"
        export CODE_NOTIFY_OMP_STATE_DIR="$root/.omp/agent"
        mkdir -p "$CODE_NOTIFY_PI_STATE_DIR" "$CODE_NOTIFY_OMP_STATE_DIR"

        # shellcheck source=/dev/null
        source "$install/lib/code-notify/utils/colors.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/utils/detect.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/core/config.sh"

        enable_tool pi || fail "enable_tool pi failed under a path containing spaces"
        enable_tool omp || fail "enable_tool omp failed under a path containing spaces"
        [[ -f "$root/.pi/agent/extensions/code-notify.ts" ]] \
            || fail "pi hook was not installed at the spaced path"
        [[ -f "$root/.omp/agent/extensions/code-notify.ts" ]] \
            || fail "omp hook was not installed at the spaced path"

        is_tool_enabled pi || fail "is_tool_enabled pi is false under a path containing spaces"
        is_tool_enabled omp || fail "is_tool_enabled omp is false under a path containing spaces"

        disable_tool pi || fail "disable_tool pi failed under a path containing spaces"
        [[ ! -e "$root/.pi/agent/extensions/code-notify.ts" ]] \
            || fail "cn off left the pi hook behind under a path containing spaces"

        # The truncation this guards against would have created (or looked for)
        # a path ending at the first space.
        [[ ! -e "${root%% *}" ]] || fail "a truncated path was used: ${root%% *} exists"
    )

    rm -rf "$base"
}

run_stale_hook_test() {
    local root
    root="$(mktemp -d)"

    (
        export HOME="$root"
        export CODE_NOTIFY_PI_STATE_DIR="$root/.pi/agent"
        mkdir -p "$CODE_NOTIFY_PI_STATE_DIR/extensions"

        load_lib

        # A hook from an older code-notify: present, but not what we ship.
        printf 'export default function () {}\n' > "$root/.pi/agent/extensions/code-notify.ts"

        if is_tool_enabled pi; then
            fail "a stale hook reported as ENABLED instead of needing repair"
        fi
        is_container_hooks_present pi || fail "a stale hook was not seen as present"
        is_tool_disable_needed pi || fail "cn off would have skipped a stale hook, leaving it spooling"

        enable_tool pi || fail "cn on did not refresh a stale hook"
        is_tool_enabled pi || fail "the refreshed hook still does not match what we ship"
    )

    rm -rf "$root"
}

run_launcher_detection_test() {
    local tasks conf_home
    tasks="$(mktemp -d)"
    conf_home="$(mktemp -d)"

    mkdir -p "$tasks/tasks/pi" "$tasks/tasks/omp" "$conf_home/.config/mise/conf.d"
    printf 'includes = ["%s/tasks"]\n' "$tasks" \
        > "$conf_home/.config/mise/conf.d/pi-less-yolo.toml"

    # pi fully wired; omp carries only a comment mentioning the bridge.
    printf 'CODE_NOTIFY_RELAY_SESSION_PID=$$ code-notify relay "${_PI_VARIANT}" "${_CN_SPOOL_HOST}" &\n' \
        > "$tasks/tasks/pi/_docker_flags"
    printf '_cn_relay_start\n' > "$tasks/tasks/pi/_default"
    printf '# see code-notify relay for how the bridge works\n' > "$tasks/tasks/omp/_default"

    (
        export HOME="$conf_home"
        load_lib
        # shellcheck source=/dev/null
        source "$LIB_DIR/commands/global.sh"

        container_agent_launcher_patched pi \
            || fail "pi's relay wiring was not detected"

        # `if` rather than `&& fail`: a correct "not wired" answer is a non-zero
        # return, which under set -e would end the subshell silently — the test
        # would look like it passed by never running.
        if container_agent_launcher_patched omp; then
            fail "omp claimed a relay it does not have (inherited from pi, or matched a comment)"
        fi

        # A commented-out invocation in the shared flags file is documentation,
        # not wiring.
        printf '# code-notify relay is started below\n' > "$tasks/tasks/pi/_docker_flags"
        if container_agent_launcher_patched pi; then
            fail "a commented-out relay invocation counted as wiring"
        fi
    ) || exit 1

    rm -rf "$tasks" "$conf_home"
}

run_spaced_path_test
pass "hook install, detect and remove survive paths containing spaces"

run_stale_hook_test
pass "a hook from another code-notify version reads as repair-needed and is still removable"

run_launcher_detection_test
pass "launcher relay detection is per-agent and ignores comments"

echo "All container agent tests passed"
