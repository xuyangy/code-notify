#!/bin/bash

# Timed notification snooze ("cn snooze 30m"). State is a single epoch
# timestamp in a marker file; expiry is evaluated lazily by the notifier,
# so no daemon or background timer is needed.

SNOOZE_FILE="$HOME/.claude/notifications/snooze-until"

# Convert "30m" / "2h" / "45s" / bare minutes into seconds.
snooze_parse_duration_seconds() {
    local raw="$1"
    if [[ ! "$raw" =~ ^([0-9]+)([smhSMH]?)$ ]]; then
        return 1
    fi
    local value="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[2]}" in
        s|S) printf '%s\n' "$value" ;;
        h|H) printf '%s\n' "$((value * 3600))" ;;
        *) printf '%s\n' "$((value * 60))" ;;
    esac
}

# Active snooze check; clears expired or malformed state on the way out.
snooze_is_active() {
    local until_ts now_ts
    [[ -f "$SNOOZE_FILE" ]] || return 1
    until_ts=$(head -n 1 "$SNOOZE_FILE" 2>/dev/null)
    if [[ ! "$until_ts" =~ ^[0-9]+$ ]]; then
        rm -f "$SNOOZE_FILE"
        return 1
    fi
    now_ts=$(date +%s)
    if (( now_ts >= until_ts )); then
        rm -f "$SNOOZE_FILE"
        return 1
    fi
    return 0
}

snooze_remaining_human() {
    local until_ts now_ts remaining
    until_ts=$(head -n 1 "$SNOOZE_FILE" 2>/dev/null)
    [[ "$until_ts" =~ ^[0-9]+$ ]] || return 1
    now_ts=$(date +%s)
    remaining=$((until_ts - now_ts))
    (( remaining > 0 )) || return 1
    if (( remaining >= 3600 )); then
        printf '%dh%02dm\n' "$((remaining / 3600))" "$(((remaining % 3600) / 60))"
    elif (( remaining >= 60 )); then
        printf '%dm\n' "$((remaining / 60))"
    else
        printf '%ds\n' "$remaining"
    fi
}

handle_snooze_command() {
    local arg="${1:-status}"

    case "$arg" in
        "off")
            rm -f "$SNOOZE_FILE"
            success "Snooze cleared - notifications resume immediately"
            ;;
        "status")
            if snooze_is_active; then
                echo "Notifications snoozed for another $(snooze_remaining_human)"
            else
                echo "Snooze is not active"
            fi
            ;;
        "help"|"-h"|"--help")
            show_snooze_help
            ;;
        *)
            local seconds until_ts until_human
            if ! seconds=$(snooze_parse_duration_seconds "$arg"); then
                error "Invalid duration: $arg (use 30m, 2h, 90s, or a number of minutes)"
                return 1
            fi
            until_ts=$(( $(date +%s) + seconds ))
            mkdir -p "$(dirname "$SNOOZE_FILE")"
            printf '%s\n' "$until_ts" > "$SNOOZE_FILE"
            # BSD date uses -r, GNU date uses -d
            until_human=$(date -r "$until_ts" '+%H:%M' 2>/dev/null || date -d "@$until_ts" '+%H:%M' 2>/dev/null || echo "")
            success "Notifications snoozed for $arg${until_human:+ (until $until_human)}"
            ;;
    esac
}
