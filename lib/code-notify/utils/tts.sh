#!/bin/bash

# Text-to-speech engine utilities for Code-Notify
# https://github.com/xuyangy/code-notify
#
# Engines: "system" (macOS `say`, default) and "elevenlabs" (cloud TTS via curl).
# Config (~/.config/code-notify/tts.json) mirrors channels.json: atomic write,
# 0600 perms, API key redacted in status. Synthesized audio is cached on disk
# so repeated phrases ("Claude completed the task") avoid repeat API calls.

TTS_CONFIG_DIR="${CODE_NOTIFY_CONFIG_DIR:-$HOME/.config/code-notify}"
TTS_CONFIG_FILE="$TTS_CONFIG_DIR/tts.json"
TTS_CACHE_DIR="${CODE_NOTIFY_CACHE_DIR:-$HOME/.cache/code-notify/tts}"

# Flash v2.5 is the fastest/cheapest model, suited to short phrases.
TTS_DEFAULT_VOICE_ID="21m00Tcm4TlvDq8ikWAM"
TTS_DEFAULT_MODEL_ID="eleven_flash_v2_5"
TTS_DEFAULT_OUTPUT_FORMAT="mp3_44100_128"
TTS_ELEVENLABS_BASE_URL="${CODE_NOTIFY_ELEVENLABS_BASE_URL:-https://api.elevenlabs.io}"

tts_has_python3() {
    command -v python3 &> /dev/null
}

tts_has_curl() {
    command -v curl &> /dev/null
}

ensure_tts_config_dir() {
    mkdir -p "$TTS_CONFIG_DIR"
    chmod 700 "$TTS_CONFIG_DIR" 2>/dev/null || true
}

tts_default_json() {
    printf '%s\n' '{"engine":"system","elevenlabs":{}}'
}

tts_read_json() {
    if [[ -f "$TTS_CONFIG_FILE" ]]; then
        cat "$TTS_CONFIG_FILE"
    else
        tts_default_json
    fi
}

tts_write_json() {
    local json="$1"
    local tmp_file

    ensure_tts_config_dir
    tmp_file=$(mktemp "$TTS_CONFIG_DIR/.tts.XXXXXX") || return 1
    printf '%s\n' "$json" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }
    chmod 600 "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$TTS_CONFIG_FILE"
}

tts_get_value() {
    local path="$1"

    tts_has_python3 || return 1
    TTS_JSON="$(tts_read_json)" python3 - "$path" <<'PY'
import json
import os
import sys

path = sys.argv[1].split(".")
try:
    data = json.loads(os.environ.get("TTS_JSON", "{}"))
except Exception:
    data = {}

value = data
for key in path:
    if isinstance(value, dict) and key in value:
        value = value[key]
    else:
        value = ""
        break

if value is None:
    value = ""
print(value)
PY
}

tts_set_value() {
    local path="$1"
    local value="$2"
    local current updated

    tts_has_python3 || { error "python3 is required to manage TTS settings"; return 1; }

    current="$(tts_read_json)"
    updated=$(TTS_JSON="$current" python3 - "$path" "$value" <<'PY'
import json
import os
import sys

path = sys.argv[1].split(".")
value = sys.argv[2]
try:
    data = json.loads(os.environ.get("TTS_JSON", "{}"))
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}

cursor = data
for key in path[:-1]:
    nxt = cursor.get(key)
    if not isinstance(nxt, dict):
        nxt = {}
        cursor[key] = nxt
    cursor = nxt
cursor[path[-1]] = value

print(json.dumps(data, separators=(",", ":")))
PY
) || return 1

    tts_write_json "$updated"
}

tts_get_engine() {
    local engine
    engine="$(tts_get_value "engine" 2>/dev/null || true)"
    [[ -n "$engine" ]] && printf '%s\n' "$engine" || printf '%s\n' "system"
}

tts_set_engine() {
    local engine="$1"
    case "$engine" in
        system|elevenlabs) ;;
        *)
            error "Unknown TTS engine: $engine (expected system or elevenlabs)"
            return 1
            ;;
    esac
    tts_set_value "engine" "$engine"
}

tts_elevenlabs_key() {
    # An exported ELEVENLABS_API_KEY wins over the stored config, so the secret
    # can live in the shell environment instead of plaintext in tts.json. The
    # hook inherits this from the process that launched the CLI.
    if [[ -n "${ELEVENLABS_API_KEY:-}" ]]; then
        printf '%s\n' "$ELEVENLABS_API_KEY"
        return 0
    fi
    tts_get_value "elevenlabs.api_key" 2>/dev/null || true
}

tts_elevenlabs_voice_id() {
    local v
    v="$(tts_get_value "elevenlabs.voice_id" 2>/dev/null || true)"
    [[ -n "$v" ]] && printf '%s\n' "$v" || printf '%s\n' "$TTS_DEFAULT_VOICE_ID"
}

tts_elevenlabs_model_id() {
    local m
    m="$(tts_get_value "elevenlabs.model_id" 2>/dev/null || true)"
    [[ -n "$m" ]] && printf '%s\n' "$m" || printf '%s\n' "$TTS_DEFAULT_MODEL_ID"
}

tts_elevenlabs_ready() {
    [[ "$(tts_get_engine)" == "elevenlabs" ]] || return 1
    tts_has_curl || return 1
    [[ -n "$(tts_elevenlabs_key)" ]] || return 1
    return 0
}

ensure_tts_cache_dir() {
    mkdir -p "$TTS_CACHE_DIR" 2>/dev/null || true
}

tts_cache_key() {
    local text="$1"
    local voice="$2"
    local model="$3"
    local raw="${voice}|${model}|${text}"

    if command -v shasum &> /dev/null; then
        printf '%s' "$raw" | shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum &> /dev/null; then
        printf '%s' "$raw" | sha256sum | awk '{print $1}'
    else
        printf 'nocache-%s' "$RANDOM"
    fi
}

tts_cache_path() {
    local key="$1"
    printf '%s/tts-%s.mp3\n' "$TTS_CACHE_DIR" "$key"
}

# Build the request body via python to safely escape quotes/newlines in text.
tts_elevenlabs_payload() {
    local text="$1"
    local model="$2"

    if tts_has_python3; then
        TTS_TEXT="$text" TTS_MODEL="$model" python3 - <<'PY'
import json
import os

print(json.dumps({
    "text": os.environ.get("TTS_TEXT", ""),
    "model_id": os.environ.get("TTS_MODEL", ""),
    "voice_settings": {
        "stability": 0.5,
        "similarity_boost": 0.75,
        "style": 0.0,
        "use_speaker_boost": True,
    },
}, separators=(",", ":")))
PY
    else
        local escaped="${text//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        escaped="${escaped//$'\n'/ }"
        printf '{"text":"%s","model_id":"%s"}' "$escaped" "$model"
    fi
}

tts_elevenlabs_synthesize() {
    local text="$1"
    local out_file="$2"
    local api_key voice_id model_id payload http_code url tmp_file

    api_key="$(tts_elevenlabs_key)"
    voice_id="$(tts_elevenlabs_voice_id)"
    model_id="$(tts_elevenlabs_model_id)"

    [[ -n "$api_key" ]] || return 1
    tts_has_curl || return 1

    payload="$(tts_elevenlabs_payload "$text" "$model_id")" || return 1
    url="$TTS_ELEVENLABS_BASE_URL/v1/text-to-speech/$voice_id?output_format=$TTS_DEFAULT_OUTPUT_FORMAT"

    mkdir -p "$(dirname "$out_file")" 2>/dev/null || true
    tmp_file=$(mktemp "${out_file}.XXXXXX") || return 1

    TTS_LAST_ERROR=""

    http_code=$(curl -X POST "$url" \
        -H "xi-api-key: $api_key" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        -o "$tmp_file" \
        -w "%{http_code}" \
        -m "${CODE_NOTIFY_TTS_TIMEOUT_SECONDS:-15}" \
        -s 2>/dev/null)

    if [[ "$http_code" == "200" ]] && [[ -s "$tmp_file" ]]; then
        mv "$tmp_file" "$out_file"
        return 0
    fi

    # shellcheck disable=SC2034  # read by callers in commands/global.sh
    TTS_LAST_ERROR="$(tts_extract_api_error "$http_code" "$tmp_file")"
    rm -f "$tmp_file"
    return 1
}

# Turn an ElevenLabs error response into a human-readable message. The error
# body is JSON like {"detail":{"message":"...","status":"..."}}.
tts_extract_api_error() {
    local http_code="$1"
    local body_file="$2"
    local msg=""

    if [[ -z "$http_code" || "$http_code" == "000" ]]; then
        printf 'could not reach ElevenLabs (network error or timeout)'
        return
    fi

    if [[ -s "$body_file" ]] && tts_has_python3; then
        msg="$(TTS_ERR_FILE="$body_file" python3 - <<'PY'
import json, os
try:
    with open(os.environ["TTS_ERR_FILE"]) as f:
        data = json.load(f)
except Exception:
    raise SystemExit(0)
detail = data.get("detail", data)
if isinstance(detail, dict):
    print(detail.get("message", "") or detail.get("status", ""))
elif isinstance(detail, str):
    print(detail)
PY
)"
    fi

    if [[ -n "$msg" ]]; then
        printf 'HTTP %s: %s' "$http_code" "$msg"
    else
        printf 'HTTP %s from ElevenLabs' "$http_code"
    fi
}

tts_elevenlabs_speak() {
    local text="$1"
    local voice_id model_id key cache_file

    [[ -n "$text" ]] || return 1
    tts_elevenlabs_ready || return 1

    voice_id="$(tts_elevenlabs_voice_id)"
    model_id="$(tts_elevenlabs_model_id)"

    ensure_tts_cache_dir
    key="$(tts_cache_key "$text" "$voice_id" "$model_id")"
    cache_file="$(tts_cache_path "$key")"

    if [[ -s "$cache_file" ]]; then
        play_sound "$cache_file"
        return 0
    fi

    if tts_elevenlabs_synthesize "$text" "$cache_file"; then
        play_sound "$cache_file"
        return 0
    fi

    return 1
}

# Public entry point for notifier.sh. $1 = message, $2 = system voice for the
# `say` fallback used when ElevenLabs is unselected or fails.
speak_notification() {
    local message="$1"
    local system_voice="${2:-}"

    [[ -n "$message" ]] || return 0

    if tts_elevenlabs_ready; then
        if tts_elevenlabs_speak "$message"; then
            return 0
        fi
    fi

    if command -v say &> /dev/null && [[ -n "$system_voice" ]]; then
        say -v "$system_voice" "$message"
        return 0
    fi

    return 1
}

tts_elevenlabs_list_voices() {
    local api_key

    api_key="$(tts_elevenlabs_key)"
    [[ -n "$api_key" ]] || { error "No ElevenLabs API key set (cn voice elevenlabs key <api-key>)"; return 1; }
    tts_has_curl || { error "curl is required to list voices"; return 1; }
    tts_has_python3 || { error "python3 is required to list voices"; return 1; }

    local response
    response=$(curl -s -m "${CODE_NOTIFY_TTS_TIMEOUT_SECONDS:-15}" \
        "$TTS_ELEVENLABS_BASE_URL/v1/voices" \
        -H "xi-api-key: $api_key" 2>/dev/null) || {
        error "Failed to reach ElevenLabs"
        return 1
    }

    TTS_VOICES_JSON="$response" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ.get("TTS_VOICES_JSON", "{}"))
except Exception:
    print("Could not parse ElevenLabs response", file=sys.stderr)
    sys.exit(1)

voices = data.get("voices")
if not isinstance(voices, list):
    detail = data.get("detail", {})
    msg = detail.get("message") if isinstance(detail, dict) else detail
    print("ElevenLabs error: %s" % (msg or "unknown"), file=sys.stderr)
    sys.exit(1)

# professional/library voices require a paid plan to use via the API; premade
# and the account's own cloned/generated voices work on the free tier.
PAID_ONLY = {"professional", "library"}

print("%-24s %-26s %-13s %s" % ("VOICE ID", "NAME", "CATEGORY", "PLAN"))
for v in voices:
    name = (v.get("name", "") or "")[:26]
    vid = v.get("voice_id", "")
    category = v.get("category", "") or "?"
    plan = "paid only" if category in PAID_ONLY else "free ok"
    print("%-24s %-26s %-13s %s" % (vid, name, category, plan))
PY
}
