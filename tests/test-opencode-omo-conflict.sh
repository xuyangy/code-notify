#!/bin/bash

# opencode + oh-my-openagent: the duplicate-notification hint.
#
# oh-my-openagent ships a session-notification hook of its own. It stands down
# when it detects another notification plugin, but it only looks at the `plugin`
# array of opencode's config and only for a short list of known package names —
# and code-notify is a drop-in file in plugin/, which opencode auto-loads without
# the config ever naming it. So nothing on either side notices, both notifiers
# stay on, and every turn end toasts twice.
#
# What this pins down:
#   - the hint fires at all, and through `cn on opencode` rather than only from
#     its own helper: it is wired at two exits (fresh install and an install that
#     is already in place), and the second is the one a user chasing duplicate
#     toasts actually hits;
#   - it names the oh-my-openagent config that exists, so the path it prints is
#     the file to edit;
#   - it stays silent once disabled_hooks mentions the hook, when the plugin is
#     not installed at all, and when the only mention of it in opencode's config
#     is a commented-out plugin entry (that config is JSONC);
#   - it never writes to oh-my-openagent's config, which belongs to another tool.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
LIB_DIR="$ROOT_DIR/lib/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

HINT='disabled_hooks'

# Runs one scenario in a subshell with its own fake opencode config dir.
#   $1 label, $2 contents of opencode.jsonc (empty for no file),
#   $3 basename of an oh-my-openagent config to create (empty for none),
#   $4 contents of that config, $5 "hint" or "silent"
run_case() {
    local label="$1" plugin_config="$2" omo_name="$3" omo_body="$4" expect="$5"
    local root config_dir output

    root="$(mktemp -d "$test_dir/case.XXXXXX")"
    config_dir="$root/.config/opencode"
    mkdir -p "$config_dir"

    [[ -z "$plugin_config" ]] || printf '%s\n' "$plugin_config" > "$config_dir/opencode.jsonc"
    [[ -z "$omo_name" ]] || printf '%s\n' "$omo_body" > "$config_dir/$omo_name"

    output="$(
        export HOME="$root"
        export CODE_NOTIFY_OPENCODE_CONFIG_DIR="$config_dir"

        # shellcheck source=/dev/null
        source "$LIB_DIR/utils/colors.sh"
        # shellcheck source=/dev/null
        source "$LIB_DIR/utils/detect.sh"
        # shellcheck source=/dev/null
        source "$LIB_DIR/utils/help.sh"
        # shellcheck source=/dev/null
        source "$LIB_DIR/core/config.sh"
        # shellcheck source=/dev/null
        source "$LIB_DIR/commands/global.sh"

        warn_if_opencode_omo_conflict 2>&1
    )"

    if [[ "$expect" == "hint" ]]; then
        printf '%s' "$output" | grep -q "$HINT" ||
            fail "$label: expected the duplicate-notification hint, got: $output"
    else
        if printf '%s' "$output" | grep -q "$HINT"; then
            fail "$label: unexpected hint: $output"
        fi
    fi

    # The hint must never be a rewrite of another tool's config.
    if [[ -n "$omo_name" ]]; then
        printf '%s\n' "$omo_body" | diff -q - "$config_dir/$omo_name" > /dev/null ||
            fail "$label: oh-my-openagent's config was modified"
    fi

    printf '%s' "$output"
}

# ---------------------------------------------------------------------------
# When it fires, and which config it names.
# ---------------------------------------------------------------------------
live_plugin='{ "plugin": ["oh-my-openagent@latest"] }'

run_case "plugin installed, no omo config" "$live_plugin" "" "" hint > /dev/null
pass "the hint fires when oh-my-openagent is a live plugin entry"

# With no config to append to, the snippet is the whole file the user will
# create. A bare `"disabled_hooks": [...]` is not JSON, so oh-my-openagent would
# fail to read it and keep notifying — the hint would look followed and change
# nothing. Parse it rather than eyeball it.
no_config="$(run_case "no omo config" "$live_plugin" "" "" hint)"
snippet="$(printf '%s\n' "$no_config" | grep 'disabled_hooks' | tail -1 | sed 's/^[[:space:]]*//')"
printf '%s' "$snippet" | python3 -c '
import json, sys
parsed = json.loads(sys.stdin.read())
assert parsed == {"disabled_hooks": ["session-notification"]}, parsed
' || fail "the create-a-config snippet is not a valid JSON object: $snippet"
pass "the snippet for a missing config is valid, complete JSON"

# With a config already present the snippet is a property to add to the object
# it holds, so on its own it is deliberately not a document.
with_config="$(run_case "existing omo config" "$live_plugin" \
    "oh-my-openagent.json" '{ "agents": {} }' hint)"
printf '%s' "$with_config" | grep -q '{ "disabled_hooks"' &&
    fail "an existing config was told to add a whole object, which would nest badly"
printf '%s' "$with_config" | python3 -c '
import json, sys
for line in sys.stdin:
    if "disabled_hooks" not in line:
        continue
    body = line.strip()
    json.loads("{" + body + "}")
    break
else:
    raise SystemExit("no disabled_hooks line found")
' || fail "the add-to-config snippet is not a valid JSON property"
pass "the snippet for an existing config is a property, valid inside its object"

named="$(run_case "existing omo config" "$live_plugin" \
    "oh-my-openagent.json" '{ "agents": {} }' hint)"
printf '%s' "$named" | grep -q 'oh-my-openagent.json' ||
    fail "the hint does not name the oh-my-openagent config that exists: $named"
pass "the hint names the config that is already there"

# The legacy basename is still what a long-standing install has.
legacy="$(run_case "legacy omo config" '{ "plugin": ["oh-my-opencode"] }' \
    "oh-my-opencode.json" '{ "agents": {} }' hint)"
printf '%s' "$legacy" | grep -q 'oh-my-opencode.json' ||
    fail "the legacy oh-my-opencode config is not recognised: $legacy"
pass "the legacy plugin name and config basename are recognised"

# ---------------------------------------------------------------------------
# When it must stay quiet. A hint that cannot be silenced is a hint people
# learn to ignore, including on the turn it finally matters.
# ---------------------------------------------------------------------------
run_case "already disabled" "$live_plugin" "oh-my-openagent.json" \
    '{ "disabled_hooks": ["session-notification"] }' silent > /dev/null
pass "the hint stops once the hook is disabled"

run_case "no opencode config" "" "" "" silent > /dev/null
pass "no opencode config means no hint"

run_case "plugin not installed" '{ "plugin": ["@ex-machina/opencode-anthropic-auth"] }' \
    "" "" silent > /dev/null
pass "an unrelated plugin does not trigger the hint"

# JSONC: a commented-out entry is not a loaded plugin.
run_case "commented-out entry" '{
    "plugin": [
        // "oh-my-openagent@latest",
        "@ex-machina/opencode-anthropic-auth"
    ]
}' "" "" silent > /dev/null
pass "a commented-out plugin entry does not trigger the hint"

# ---------------------------------------------------------------------------
# Wiring: the hint has to reach the user through `cn on opencode` itself, at
# both of its exits. A helper nobody calls delivers nothing.
# ---------------------------------------------------------------------------
run_wiring_test() {
    local base root install config_dir fake_bin first second

    base="$(mktemp -d "$test_dir/wiring.XXXXXX")"
    root="$base/home"
    install="$base/install"
    config_dir="$root/.config/opencode"
    fake_bin="$base/bin"
    mkdir -p "$root" "$install" "$config_dir" "$fake_bin"
    /bin/cp -R "$ROOT_DIR/lib" "$install/lib"

    # detect_opencode keys on the command being present, not on a config file.
    printf '#!/bin/bash\nexit 0\n' > "$fake_bin/opencode"
    chmod +x "$fake_bin/opencode"

    printf '%s\n' "$live_plugin" > "$config_dir/opencode.jsonc"

    first="$(
        export HOME="$root"
        export PATH="$fake_bin:$PATH"
        export CODE_NOTIFY_OPENCODE_CONFIG_DIR="$config_dir"

        # shellcheck source=/dev/null
        source "$install/lib/code-notify/utils/colors.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/utils/detect.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/utils/help.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/core/config.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/commands/global.sh"

        enable_single_tool opencode 2>&1
    )"

    printf '%s' "$first" | grep -q "$HINT" ||
        fail "a fresh \`cn on opencode\` does not print the hint: $first"
    [[ -f "$config_dir/plugin/code-notify.ts" ]] ||
        fail "the plugin was not installed during the wiring test"

    # Re-running against an install already in place returns early — the path
    # someone who is already getting two toasts arrives on.
    second="$(
        export HOME="$root"
        export PATH="$fake_bin:$PATH"
        export CODE_NOTIFY_OPENCODE_CONFIG_DIR="$config_dir"

        # shellcheck source=/dev/null
        source "$install/lib/code-notify/utils/colors.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/utils/detect.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/utils/help.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/core/config.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/commands/global.sh"

        enable_single_tool opencode 2>&1
    )"

    printf '%s' "$second" | grep -q 'already enabled' ||
        fail "the second run did not take the already-enabled path: $second"
    printf '%s' "$second" | grep -q "$HINT" ||
        fail "re-running \`cn on opencode\` does not print the hint: $second"

    # Bulk `cn on` is the documented way to install, so the quiet argument must
    # not swallow this the way it swallows routine progress chatter.
    local quiet
    quiet="$(
        export HOME="$root"
        export PATH="$fake_bin:$PATH"
        export CODE_NOTIFY_OPENCODE_CONFIG_DIR="$config_dir"

        # shellcheck source=/dev/null
        source "$install/lib/code-notify/utils/colors.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/utils/detect.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/utils/help.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/core/config.sh"
        # shellcheck source=/dev/null
        source "$install/lib/code-notify/commands/global.sh"

        enable_single_tool opencode quiet 2>&1
    )"

    printf '%s' "$quiet" | grep -q "$HINT" ||
        fail "a bulk \`cn on\` swallows the hint: $quiet"
}

run_wiring_test
pass "the hint reaches the user through cn on opencode, quiet or not"

echo "All opencode oh-my-openagent conflict tests passed"
