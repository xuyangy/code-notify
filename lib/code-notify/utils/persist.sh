#!/bin/bash

# Persistent ("sticky") notification configuration. Selected alert types are
# delivered as alerts that stay visible until the user closes them, or until
# a configurable timeout (default 12 hours), instead of auto-hiding banners.
# State is two small files shared with the Windows PowerShell notifier:
#   persist-types   - pipe-separated canonical type keys
#   persist-timeout - seconds an alert stays visible; 0 = until closed

PERSIST_TYPES_FILE="$HOME/.claude/notifications/persist-types"
PERSIST_TIMEOUT_FILE="$HOME/.claude/notifications/persist-timeout"
PERSIST_DEFAULT_TIMEOUT_SECONDS=43200  # 12 hours

persist_get_types() {
    [[ -f "$PERSIST_TYPES_FILE" ]] || return 0
    head -n 1 "$PERSIST_TYPES_FILE" 2>/dev/null
}

persist_set_types() {
    mkdir -p "$(dirname "$PERSIST_TYPES_FILE")"
    printf '%s\n' "$1" > "$PERSIST_TYPES_FILE"
}

# Exact match against the canonical type keys stored in persist-types.
persist_is_type_enabled() {
    local type="$1"
    local current item
    local -a _persist_types=()

    [[ -n "$type" ]] || return 1
    current="$(persist_get_types)"
    [[ -n "$current" ]] || return 1

    IFS='|' read -r -a _persist_types <<< "$current"
    for item in "${_persist_types[@]}"; do
        [[ "$item" == "$type" ]] && return 0
    done

    return 1
}

# Expects a canonical type (caller normalizes via normalize_persist_type).
persist_add_type() {
    local type="$1"
    local current

    if persist_is_type_enabled "$type"; then
        return 0
    fi

    current="$(persist_get_types)"
    if [[ -z "$current" ]]; then
        persist_set_types "$type"
    else
        persist_set_types "$current|$type"
    fi
}

persist_remove_type() {
    local type="$1"
    local current item new=""
    local -a _persist_types=()

    current="$(persist_get_types)"
    IFS='|' read -r -a _persist_types <<< "$current"
    for item in "${_persist_types[@]}"; do
        [[ -n "$item" ]] || continue
        [[ "$item" != "$type" ]] || continue
        if [[ -z "$new" ]]; then
            new="$item"
        else
            new="$new|$item"
        fi
    done

    if [[ -z "$new" ]]; then
        rm -f "$PERSIST_TYPES_FILE"
    else
        persist_set_types "$new"
    fi
}

# Seconds a persistent alert stays visible; 0 means until manually closed.
persist_get_timeout_seconds() {
    local raw
    if [[ -f "$PERSIST_TIMEOUT_FILE" ]]; then
        raw=$(head -n 1 "$PERSIST_TIMEOUT_FILE" 2>/dev/null)
        if [[ "$raw" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$raw"
            return 0
        fi
    fi
    printf '%s\n' "$PERSIST_DEFAULT_TIMEOUT_SECONDS"
}

persist_set_timeout_seconds() {
    local seconds="$1"
    [[ "$seconds" =~ ^[0-9]+$ ]] || return 1
    mkdir -p "$(dirname "$PERSIST_TIMEOUT_FILE")"
    printf '%s\n' "$seconds" > "$PERSIST_TIMEOUT_FILE"
}

persist_reset() {
    rm -f "$PERSIST_TYPES_FILE" "$PERSIST_TIMEOUT_FILE"
}

persist_timeout_human() {
    local seconds
    seconds="$(persist_get_timeout_seconds)"
    if (( seconds == 0 )); then
        printf '%s\n' "until manually closed"
    elif (( seconds % 3600 == 0 )); then
        printf '%dh\n' "$((seconds / 3600))"
    elif (( seconds % 60 == 0 )); then
        printf '%dm\n' "$((seconds / 60))"
    else
        printf '%ds\n' "$seconds"
    fi
}
