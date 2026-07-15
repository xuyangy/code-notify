#!/bin/bash

# ElevenLabs cache entries should be grouped visibly by project and must not
# collide when the same message is spoken from different worktrees.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
export CODE_NOTIFY_CACHE_DIR="$test_dir/cache"
source "$ROOT_DIR/lib/code-notify/utils/tts.sh"

key_one="$(tts_cache_key 'Task complete' voice model first-project)"
key_two="$(tts_cache_key 'Task complete' voice model second-project)"
[[ "$key_one" != "$key_two" ]] || fail "cache key should include the project"

cache_path="$(tts_cache_path "$key_one" 'My Project!')"
[[ "$cache_path" == "$CODE_NOTIFY_CACHE_DIR/tts-My-Project-$key_one.mp3" ]] ||
    fail "cache filename should include a safe project label"

pass "TTS cache separates and labels projects"
