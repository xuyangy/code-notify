#!/bin/bash

# Channels and usage alerts are asked about after every notification. With no
# channels.json / usage.json (the default for most users) the answer is
# "nothing to do", and it must come without starting python3. With a config
# file present the answer still comes from that file.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

REAL_PYTHON3="$(command -v python3 || true)"
if [[ -z "$REAL_PYTHON3" ]]; then
    echo "SKIP: python3 not available"
    exit 0
fi

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR/home"
export CODE_NOTIFY_CONFIG_DIR="$TEST_DIR/config"
mkdir -p "$HOME" "$CODE_NOTIFY_CONFIG_DIR" "$TEST_DIR/bin"
python_log="$TEST_DIR/python3.calls"

# Counts python3 starts, then runs the real interpreter.
cat > "$TEST_DIR/bin/python3" <<EOF
#!/bin/bash
echo call >> "$python_log"
exec "$REAL_PYTHON3" "\$@"
EOF
chmod +x "$TEST_DIR/bin/python3"
export PATH="$TEST_DIR/bin:$PATH"

source "$LIB_DIR/utils/channels.sh"
source "$LIB_DIR/utils/usage.sh"

calls() { [[ -f "$python_log" ]] && wc -l < "$python_log" | tr -d ' ' || echo 0; }

[[ -z "$(channels_emit_entries)" ]] || fail "channels emitted entries without a config file"
if usage_is_provider_enabled claude; then
    fail "usage reported claude enabled without a config file"
fi
[[ "$(calls)" == "0" ]] || fail "python3 started $(calls) time(s) with no channels/usage config"
pass "no python3 start when channels and usage are unconfigured"

printf '%s\n' '{"enabled":true,"channels":[{"name":"phone","provider":"ntfy","url":"https://ntfy.sh/t"}]}' \
    > "$CODE_NOTIFY_CONFIG_DIR/channels.json"
printf '%s\n' '{"enabled":true,"providers":["claude"],"provider_enabled":{"claude":true}}' \
    > "$CODE_NOTIFY_CONFIG_DIR/usage.json"
[[ "$(channels_emit_entries)" == $'phone\tntfy\thttps://ntfy.sh/t' ]] || fail "configured channel was not emitted"
usage_is_provider_enabled claude || fail "configured usage provider was not reported enabled"
pass "configured channels and usage providers are still read"
