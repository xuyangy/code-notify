#!/bin/bash

# Antigravity (agy) enablement + status-source tests.
#
# `cn status` and is_antigravity_enabled must reflect what agy ACTUALLY runs,
# which is its managed copy of the plugin at <manifest dir>/plugins/<name>/ — NOT
# our staging dir. The fake agy below models the real lifecycle observed against
# agy 1.0.11:
#   * install        -> copies staging into the managed dir, writes the manifest
#   * failed install -> leaves the managed copy untouched (exit 1)
#   * uninstall      -> removes the managed dir and the manifest entry
#   * disable        -> renames managed plugin.json to plugin.json.disabled,
#                       KEEPING the manifest entry
#   * enable         -> renames it back

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
mkdir -p "$HOME/.claude/notifications" "$HOME/.gemini/config" "$fake_bin"

# Fake agy modelling the managed-copy lifecycle. Paths mirror the config.sh
# defaults derived from the (fake) HOME. AGY_FAIL_INSTALL=1 makes install fail.
cat > "$fake_bin/agy" <<'EOF'
#!/bin/bash
manifest="$HOME/.gemini/config/import_manifest.json"
managed="$HOME/.gemini/config/plugins/code-notify"
case "$1 $2" in
    "plugin install")
        staging="$3"
        [[ "${AGY_FAIL_INSTALL:-0}" == "1" ]] && exit 1
        mkdir -p "$managed/hooks"
        cp "$staging/hooks.json" "$managed/hooks.json" 2>/dev/null
        cp "$staging/plugin.json" "$managed/plugin.json" 2>/dev/null
        printf '{"imports":[{"name":"code-notify"}]}' > "$manifest"
        ;;
    "plugin uninstall")
        rm -rf "$managed"
        printf '{"imports":[]}' > "$manifest"
        ;;
    "plugin disable")
        [[ -f "$managed/plugin.json" ]] && mv "$managed/plugin.json" "$managed/plugin.json.disabled"
        ;;
    "plugin enable")
        [[ -f "$managed/plugin.json.disabled" ]] && mv "$managed/plugin.json.disabled" "$managed/plugin.json"
        ;;
esac
exit 0
EOF
chmod +x "$fake_bin/agy"
export PATH="$fake_bin:$PATH"

source "$ROOT_DIR/lib/code-notify/utils/colors.sh"
source "$ROOT_DIR/lib/code-notify/core/config.sh"

# Stubs: a fixed notify script path and a togglable permission_prompt setting.
get_notify_script() { echo "$HOME/.claude/notifications/notify.sh"; }
PERMISSION_ENABLED=1
is_notify_type_enabled() { [[ "$1" == "permission_prompt" && "$PERMISSION_ENABLED" == "1" ]]; }

has_pre_tool_use() { grep -q '"PreToolUse"' "$1" 2>/dev/null; }

# 1) Enable with permission_prompt ON: import succeeds; the managed copy that
#    status reads has the live PreToolUse hook, and detection reports enabled.
PERMISSION_ENABLED=1
AGY_FAIL_INSTALL=0 enable_antigravity_hooks || fail "initial enable should succeed"
is_antigravity_enabled || fail "plugin should read as enabled after a successful import"
[[ -f "$ANTIGRAVITY_IMPORTED_HOOKS_FILE" ]] || fail "managed hooks.json should exist after import"
has_pre_tool_use "$ANTIGRAVITY_IMPORTED_HOOKS_FILE" || fail "managed copy should record the live PreToolUse hook"

# 2) A failed update must leave the managed copy (status ground truth) intact and
#    report failure, even though the attempt rewrote staging. Status reads the
#    managed copy, not staging — this is the reported status bug.
PERMISSION_ENABLED=0
AGY_FAIL_INSTALL=1 enable_antigravity_hooks 2>/dev/null \
    && fail "a failed update should report failure"
is_antigravity_enabled \
    || fail "a failed update must not disable the previously-imported plugin"
has_pre_tool_use "$ANTIGRAVITY_IMPORTED_HOOKS_FILE" \
    || fail "managed copy must still reflect the IMPORTED plugin after a failed update"

# 3) PreToolUse is always installed now (it cancels the debounce on every tool
#    start); the permission_prompt setting only gates the runtime approval banner,
#    not hooks.json. A successful import with permission OFF still records it.
PERMISSION_ENABLED=0
AGY_FAIL_INSTALL=0 enable_antigravity_hooks || fail "update should succeed"
has_pre_tool_use "$ANTIGRAVITY_IMPORTED_HOOKS_FILE" \
    || fail "managed copy must keep PreToolUse regardless of the permission_prompt setting"

# 4) `agy plugin disable` keeps the manifest entry but renames plugin.json, so a
#    disabled plugin must NOT be reported as enabled (the reported detection bug)
#    yet must still read as IMPORTED so `cn off` can uninstall it.
agy plugin disable code-notify
grep -q '"code-notify"' "$ANTIGRAVITY_IMPORT_MANIFEST" \
    || fail "test setup: manifest should retain the entry when disabled"
is_antigravity_enabled \
    && fail "a disabled plugin must not be reported as enabled"
is_antigravity_imported \
    || fail "a disabled plugin must still read as imported"
is_tool_disable_needed antigravity \
    || fail "cn off must consider a disabled-but-imported plugin to need disabling"

# 5) `cn off antigravity` (disable_antigravity_hooks) must uninstall the plugin
#    even though it was deactivated out-of-band: detection flips to not-imported
#    and the managed hooks.json is gone.
disable_antigravity_hooks || fail "disable should uninstall a disabled-but-imported plugin"
is_antigravity_imported \
    && fail "uninstall should remove a disabled-but-imported plugin"
[[ -f "$ANTIGRAVITY_IMPORTED_HOOKS_FILE" ]] \
    && fail "uninstall should remove the managed hooks.json"

pass "Antigravity enablement and status read agy's managed plugin copy as ground truth"
