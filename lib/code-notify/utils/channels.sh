#!/bin/bash

CHANNELS_DIR="${CODE_NOTIFY_CONFIG_DIR:-$HOME/.config/code-notify}"
CHANNELS_FILE="$CHANNELS_DIR/channels.json"

channels_has_python3() {
    command -v python3 >/dev/null 2>&1
}

ensure_channels_dir() {
    mkdir -p "$CHANNELS_DIR"
    chmod 700 "$CHANNELS_DIR" 2>/dev/null || true
}

channels_write_json() {
    local json="$1"
    local tmp_file

    ensure_channels_dir
    tmp_file=$(mktemp "$CHANNELS_DIR/.channels.XXXXXX") || return 1
    printf '%s\n' "$json" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$CHANNELS_FILE"
}

channels_default_json() {
    printf '%s\n' '{"enabled":true,"channels":[]}'
}

channels_read_json() {
    if [[ -f "$CHANNELS_FILE" ]]; then
        cat "$CHANNELS_FILE"
    else
        channels_default_json
    fi
}

channels_validate_provider_url() {
    local provider="$1"
    local url="$2"

    case "$provider:$url" in
        slack:https://hooks.slack.com/*|slack:https://hooks.slack-gov.com/*)
            return 0
            ;;
        discord:https://discord.com/api/webhooks/*|discord:https://discordapp.com/api/webhooks/*)
            return 0
            ;;
    esac

    return 1
}

channels_add() {
    local provider="$1"
    local url="$2"
    local name="$3"
    local current updated

    [[ -n "$name" ]] || name="$provider"

    if [[ "$provider" != "slack" && "$provider" != "discord" ]]; then
        error "Unsupported channel provider: $provider"
        return 1
    fi

    if ! channels_validate_provider_url "$provider" "$url"; then
        error "Invalid $provider webhook URL"
        return 1
    fi

    channels_has_python3 || { error "python3 is required to manage channels"; return 1; }

    current="$(channels_read_json)"
    updated=$(CHANNELS_JSON="$current" python3 - "$provider" "$name" "$url" <<'PY'
import json
import os
import sys

provider, name, url = sys.argv[1:4]
try:
    data = json.loads(os.environ.get("CHANNELS_JSON", "{}"))
except Exception:
    data = {}

channels = [c for c in data.get("channels", []) if c.get("name") != name]
channels.append({"name": name, "provider": provider, "url": url})
data["enabled"] = bool(data.get("enabled", True))
data["channels"] = channels
print(json.dumps(data, separators=(",", ":")))
PY
) || return 1

    channels_write_json "$updated"
    success "Channel saved: $name ($provider)"
}

channels_remove() {
    local name="$1"
    local current updated removed

    [[ -n "$name" ]] || { error "Please specify a channel name"; return 1; }
    channels_has_python3 || { error "python3 is required to manage channels"; return 1; }

    current="$(channels_read_json)"
    updated=$(CHANNELS_JSON="$current" python3 - "$name" <<'PY'
import json
import os
import sys

name = sys.argv[1]
try:
    data = json.loads(os.environ.get("CHANNELS_JSON", "{}"))
except Exception:
    data = {}

channels = data.get("channels", [])
new_channels = [c for c in channels if c.get("name") != name]
data["channels"] = new_channels
data["enabled"] = bool(data.get("enabled", True))
print(json.dumps({"removed": len(channels) - len(new_channels), "data": data}, separators=(",", ":")))
PY
) || return 1

    removed=$(printf '%s' "$updated" | python3 -c 'import json,sys; print(json.load(sys.stdin)["removed"])')
    if [[ "$removed" == "0" ]]; then
        error "Channel not found: $name"
        return 1
    fi

    channels_write_json "$(printf '%s' "$updated" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["data"], separators=(",", ":")))')"
    success "Channel removed: $name"
}

channels_set_enabled() {
    local enabled="$1"
    local current updated

    channels_has_python3 || { error "python3 is required to manage channels"; return 1; }
    current="$(channels_read_json)"
    updated=$(CHANNELS_JSON="$current" python3 - "$enabled" <<'PY'
import json
import os
import sys

enabled = sys.argv[1] == "true"
try:
    data = json.loads(os.environ.get("CHANNELS_JSON", "{}"))
except Exception:
    data = {}

data["enabled"] = enabled
data["channels"] = data.get("channels", [])
print(json.dumps(data, separators=(",", ":")))
PY
) || return 1
    channels_write_json "$updated"
}

channels_reset() {
    channels_write_json "$(channels_default_json)"
    success "Channels reset"
}

channels_list_redacted() {
    channels_has_python3 || return 1
    CHANNELS_JSON="$(channels_read_json)" python3 - <<'PY'
import json
import os
import sys
from urllib.parse import urlparse

try:
    data = json.loads(os.environ.get("CHANNELS_JSON", "{}"))
except Exception:
    data = {}

print("enabled\t" + ("true" if data.get("enabled", True) else "false"))
for channel in data.get("channels", []):
    parsed = urlparse(channel.get("url", ""))
    host = parsed.netloc or "unknown"
    print("\t".join([
        "channel",
        channel.get("name", ""),
        channel.get("provider", ""),
        host,
    ]))
PY
}

channels_status() {
    local line kind name provider host enabled="true" count=0

    header "${BELL} Delivery Channels"
    echo ""

    if ! channels_has_python3; then
        echo "  ${WARNING} python3 not found; channel config unavailable"
        return 0
    fi

    while IFS=$'\t' read -r kind name provider host; do
        if [[ "$kind" == "enabled" ]]; then
            enabled="$name"
            continue
        fi
        if [[ "$kind" == "channel" ]]; then
            count=$((count + 1))
            echo "  ${CHECK_MARK} $name: ${GREEN}${provider}${RESET} ($host)"
        fi
    done < <(channels_list_redacted)

    if [[ "$enabled" == "true" ]]; then
        echo "  Status: ${GREEN}ENABLED${RESET}"
    else
        echo "  Status: ${DIM}DISABLED${RESET}"
    fi

    if [[ "$count" -eq 0 ]]; then
        echo "  ${DIM}No Slack/Discord channels configured${RESET}"
    fi
}

channels_emit_entries() {
    channels_has_python3 || return 0
    CHANNELS_JSON="$(channels_read_json)" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ.get("CHANNELS_JSON", "{}"))
except Exception:
    data = {}

if not data.get("enabled", True):
    raise SystemExit(0)

for channel in data.get("channels", []):
    name = channel.get("name", "")
    provider = channel.get("provider", "")
    url = channel.get("url", "")
    if name and provider and url:
        print("\t".join([name, provider, url]))
PY
}

channels_json_payload() {
    local provider="$1"
    local title="$2"
    local message="$3"
    local context="$4"

    channels_has_python3 || return 1
    python3 - "$provider" "$title" "$message" "$context" <<'PY'
import json
import sys

provider, title, message, context = sys.argv[1:5]
text = title
if message:
    text += "\n" + message
if context:
    text += "\n" + context

if provider == "discord":
    print(json.dumps({"content": text[:2000], "allowed_mentions": {"parse": []}}, separators=(",", ":")))
else:
    print(json.dumps({"text": text}, separators=(",", ":")))
PY
}

channels_send_one() {
    local provider="$1"
    local url="$2"
    local title="$3"
    local message="$4"
    local context="$5"
    local payload

    command -v curl >/dev/null 2>&1 || return 0
    payload="$(channels_json_payload "$provider" "$title" "$message" "$context")" || return 0
    curl -fsS -m "${CODE_NOTIFY_CHANNEL_TIMEOUT_SECONDS:-5}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$url" >/dev/null 2>&1 || return 0
}

channels_deliver() {
    local title="$1"
    local message="$2"
    local tool="${3:-}"
    local project="${4:-}"
    local extra="${5:-}"
    local name provider url context

    context=""
    [[ -n "$tool" ]] && context="Tool: $tool"
    [[ -n "$project" ]] && context="${context}${context:+ | }Project: $project"
    [[ -n "$extra" ]] && context="${context}${context:+ | }$extra"

    while IFS=$'\t' read -r name provider url; do
        channels_send_one "$provider" "$url" "$title" "$message" "$context" &
    done < <(channels_emit_entries)

    wait 2>/dev/null || true
    return 0
}

channels_test() {
    local target="${1:-all}"
    local name provider url count=0

    while IFS=$'\t' read -r name provider url; do
        if [[ "$target" != "all" && "$target" != "$name" ]]; then
            continue
        fi
        count=$((count + 1))
        channels_send_one "$provider" "$url" "Code-Notify Test" "Slack/Discord delivery is working." "Channel: $name"
    done < <(channels_emit_entries)

    if [[ "$count" -eq 0 ]]; then
        error "No matching channels configured"
        return 1
    fi

    success "Test message sent to $count channel(s)"
}

handle_channels_command() {
    local subcommand="${1:-status}"
    shift || true

    case "$subcommand" in
        "status"|"")
            channels_status
            ;;
        "add")
            local provider="${1:-}"
            local url="${2:-}"
            local name=""
            shift 2 2>/dev/null || true
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    "--name")
                        name="${2:-}"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            [[ -n "$provider" && -n "$url" ]] || { error "Usage: cn channels add <slack|discord> <webhook-url> [--name <name>]"; return 1; }
            channels_add "$provider" "$url" "$name"
            ;;
        "remove"|"rm")
            channels_remove "${1:-}"
            ;;
        "test")
            channels_test "${1:-all}"
            ;;
        "on")
            channels_set_enabled true && success "Channels enabled"
            ;;
        "off")
            channels_set_enabled false && success "Channels disabled"
            ;;
        "reset")
            channels_reset
            ;;
        "help"|"-h"|"--help")
            show_channels_help
            ;;
        *)
            error "Unknown channels command: $subcommand"
            show_channels_help
            return 1
            ;;
    esac
}
