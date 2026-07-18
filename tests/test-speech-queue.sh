#!/bin/bash

# Opt-in speech queue: with `cn voice queue on`, concurrent speakers must not
# overlap (serialized through the on-disk mutex), identical phrases spoken
# moments apart collapse into one, a phrase that waits out the queue is
# dropped instead of spoken late, and a dead speaker's lock is reclaimed.
# With the queue off (the default), voices play immediately with no waiting.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
mkdir -p "$HOME"

# Stub `say`: record start/end lines around a deliberate playback window so
# overlapping speakers are visible as two "start" lines in a row.
stub_bin="$test_dir/bin"
mkdir -p "$stub_bin"
export SAY_LOG="$test_dir/say.log"
cat > "$stub_bin/say" <<'STUB'
#!/bin/bash
shift 2  # drop "-v <voice>"
echo "start $*" >> "$SAY_LOG"
sleep "${SAY_DELAY:-0.5}"
echo "end $*" >> "$SAY_LOG"
STUB
chmod +x "$stub_bin/say"
export PATH="$stub_bin:$PATH"

source "$ROOT_DIR/lib/code-notify/utils/tts.sh"

lock_dir="$HOME/.claude/notifications/state/speech.lock"

# --- Queue off (default): speakers do not wait, even while the lock is held
: > "$SAY_LOG"
mkdir -p "$lock_dir"
printf '%s' "$$" > "$lock_dir/pid"
start_epoch=$SECONDS
speak_notification "no queue message" "TestVoice"
elapsed=$((SECONDS - start_epoch))
rm -rf "$lock_dir"
grep -q "start no queue message" "$SAY_LOG" || fail "queue off should speak immediately"
[[ "$elapsed" -le 2 ]] || fail "queue off should not wait on the lock (took ${elapsed}s)"
pass "queue off speaks immediately without waiting"

# --- Queue on: concurrent distinct phrases serialize (no interleaved starts)
enable_speech_queue
speech_queue_enabled || fail "enable_speech_queue should enable the queue"
: > "$SAY_LOG"
speak_notification "message one" "TestVoice" &
speak_notification "message two" "TestVoice" &
wait
line_count=$(wc -l < "$SAY_LOG" | tr -d ' ')
[[ "$line_count" == "4" ]] || fail "expected 4 log lines for two utterances, got $line_count"
grep -q "message one" "$SAY_LOG" || fail "first phrase should be spoken"
grep -q "message two" "$SAY_LOG" || fail "second phrase should be spoken"
line2=$(sed -n '2p' "$SAY_LOG")
line3=$(sed -n '3p' "$SAY_LOG")
[[ "$line2" == end* ]] || fail "second line should be an 'end' (voices overlapped): $line2"
[[ "$line3" == start* ]] || fail "third line should be a 'start' (voices overlapped): $line3"
pass "concurrent distinct phrases speak one at a time"

# --- Identical concurrent phrases collapse into a single utterance
: > "$SAY_LOG"
speak_notification "same message" "TestVoice" &
speak_notification "same message" "TestVoice" &
wait
line_count=$(wc -l < "$SAY_LOG" | tr -d ' ')
[[ "$line_count" == "2" ]] || fail "duplicate phrase should be spoken once, got $line_count log lines"
pass "identical concurrent phrases dedupe to one utterance"

# --- Dedup window 0 disables deduplication
: > "$SAY_LOG"
rm -f "$HOME/.claude/notifications/state/speech-last"
CODE_NOTIFY_SPEECH_DEDUP_SECONDS=0 speak_notification "repeat me" "TestVoice"
CODE_NOTIFY_SPEECH_DEDUP_SECONDS=0 speak_notification "repeat me" "TestVoice"
line_count=$(wc -l < "$SAY_LOG" | tr -d ' ')
[[ "$line_count" == "4" ]] || fail "dedup window 0 should speak both, got $line_count log lines"
pass "dedup window 0 keeps every utterance"

# --- A phrase that waits out the queue is dropped, not spoken late
: > "$SAY_LOG"
mkdir -p "$lock_dir"
printf '%s %s' "$$" "$(date +%s)" > "$lock_dir/pid"
CODE_NOTIFY_SPEECH_MAX_WAIT_SECONDS=1 speak_notification "late message" "TestVoice"
rm -rf "$lock_dir"
if grep -q "late message" "$SAY_LOG"; then
    fail "a phrase past max wait should be dropped"
fi
pass "stale phrase is dropped after max wait"

# --- Drops are logged even on a fresh install without ~/.claude/logs
grep -q "\[speech\] dropped after max wait: late message" "$HOME/.claude/logs/notifications.log" 2>/dev/null ||
    fail "dropped phrase should be logged even when ~/.claude/logs did not exist"
pass "drop decisions are logged on a fresh install"

# --- An orphaned speaker (parent hook shell already exited, as in the macOS
# notifier's detached subshell) must keep its lock for the whole utterance:
# the recorded owner pid has to be the speaker itself, not the dead parent,
# or the waiter's ~2s liveness probe reclaims the lock mid-utterance.
: > "$SAY_LOG"
SAY_DELAY=3 bash -c "source '$ROOT_DIR/lib/code-notify/utils/tts.sh'; ( speak_notification 'long orphan message' 'TestVoice' ) &"
# Poll for the start line instead of a fixed sleep: the child must source the
# library and win the lock first, which can take over half a second under
# load. The 3s utterance only begins once the start line is logged, so the
# waiter below still queues behind it no matter how long the poll took.
for _ in {1..100}; do
    grep -q "start long orphan message" "$SAY_LOG" 2>/dev/null && break
    sleep 0.1
done
grep -q "start long orphan message" "$SAY_LOG" || fail "orphan speaker should have started"
speak_notification "queued behind orphan" "TestVoice"
line2=$(sed -n '2p' "$SAY_LOG")
[[ "$line2" == "end long orphan message" ]] ||
    fail "waiter spoke over the orphaned speaker (lock stolen mid-utterance): $line2"
grep -q "end queued behind orphan" "$SAY_LOG" || fail "queued phrase should speak after the orphan finishes"
pass "orphaned speaker keeps its lock for the whole utterance"

# --- A lock left behind by a dead speaker is reclaimed
: > "$SAY_LOG"
sleep 0.1 &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
mkdir -p "$lock_dir"
printf '%s %s' "$dead_pid" "$(date +%s)" > "$lock_dir/pid"
speak_notification "recovered message" "TestVoice"
grep -q "start recovered message" "$SAY_LOG" || fail "dead speaker's lock should be reclaimed"
[[ ! -d "$lock_dir" ]] || fail "lock should be released after speaking"
pass "dead speaker's lock is reclaimed"

# --- Several waiters hitting the same stale lock must stay serialized: only
# one may win the reclaim (atomic rename), and a loser must not tear down the
# lock the winner re-acquired. All four start together, so they all reach the
# ~2s stale check nearly simultaneously.
: > "$SAY_LOG"
sleep 0.1 &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
mkdir -p "$lock_dir"
printf '%s %s' "$dead_pid" "$(date +%s)" > "$lock_dir/pid"
speak_notification "racer one" "TestVoice" &
speak_notification "racer two" "TestVoice" &
speak_notification "racer three" "TestVoice" &
speak_notification "racer four" "TestVoice" &
wait
line_count=$(wc -l < "$SAY_LOG" | tr -d ' ')
[[ "$line_count" == "8" ]] || fail "all four racers should speak once, got $line_count log lines"
line_no=0
while IFS= read -r line; do
    line_no=$((line_no + 1))
    if (( line_no % 2 == 1 )); then
        [[ "$line" == start* ]] || fail "voices overlapped during concurrent stale reclaim (line $line_no: $line)"
    else
        [[ "$line" == end* ]] || fail "voices overlapped during concurrent stale reclaim (line $line_no: $line)"
    fi
done < "$SAY_LOG"
pass "concurrent stale-lock reclaim keeps voices serialized"

# --- A reclaim mutex left behind by a killed reclaimer cannot wedge
# reclamation: it is cleared once its stamp is older than the mutex TTL.
: > "$SAY_LOG"
sleep 0.1 &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
mkdir -p "$lock_dir"
printf '%s %s' "$dead_pid" "$(date +%s)" > "$lock_dir/pid"
mkdir -p "$lock_dir.reclaim"
printf '%s' "$(( $(date +%s) - 120 ))" > "$lock_dir.reclaim/stamp"
speak_notification "reclaimed past dead mutex" "TestVoice"
grep -q "start reclaimed past dead mutex" "$SAY_LOG" ||
    fail "a dead reclaimer's mutex should be cleared and the stale lock reclaimed"
[[ ! -d "$lock_dir.reclaim" ]] || fail "the dead reclaim mutex should have been removed"
pass "dead reclaimer's mutex is cleared"

# --- A live-but-hung owner is reclaimed once the lock outlives its TTL
: > "$SAY_LOG"
mkdir -p "$lock_dir"
printf '%s %s' "$$" "$(( $(date +%s) - 3600 ))" > "$lock_dir/pid"
speak_notification "reclaimed from hung owner" "TestVoice"
grep -q "start reclaimed from hung owner" "$SAY_LOG" ||
    fail "a lock held past the TTL by a live owner should be reclaimed"
[[ ! -d "$lock_dir" ]] || fail "lock should be released after TTL reclaim"
pass "lock held past TTL by a live owner is reclaimed"

# --- An unparseable pid file cannot wedge the queue
: > "$SAY_LOG"
mkdir -p "$lock_dir"
printf 'not-a-pid' > "$lock_dir/pid"
speak_notification "reclaimed from garbage" "TestVoice"
grep -q "start reclaimed from garbage" "$SAY_LOG" ||
    fail "a lock with a garbage pid file should be reclaimed"
pass "garbage pid file is reclaimed"

# --- Release only tears down a lock this speaker still owns
speech_lock_acquire || fail "acquiring a free lock should succeed"
printf '%s %s' "999999999" "$(date +%s)" > "$lock_dir/pid"
speech_lock_release
[[ -d "$lock_dir" ]] || fail "release must not remove a lock reclaimed by another speaker"
rm -rf "$lock_dir"
pass "release is owner-checked"

# --- Env override wins over the flag file in both directions
disable_speech_queue
if speech_queue_enabled; then
    fail "disable_speech_queue should disable the queue"
fi
if ! ( export CODE_NOTIFY_SPEECH_SERIALIZE=true; speech_queue_enabled ); then
    fail "env true should enable the queue despite the flag file being absent"
fi
enable_speech_queue
if ( export CODE_NOTIFY_SPEECH_SERIALIZE=false; speech_queue_enabled ); then
    fail "env false should disable the queue despite the flag file"
fi
disable_speech_queue
pass "CODE_NOTIFY_SPEECH_SERIALIZE overrides the flag file"

# --- ElevenLabs synthesis must happen BEFORE the lock is taken (a cache-miss
# network round-trip inside the lock would starve waiting speakers into their
# max-wait drop), and a repeated phrase must reuse the cache instead of
# calling the API again.
enable_speech_queue
export ELEVENLABS_API_KEY="test-key"
mkdir -p "$HOME/.config/code-notify"
printf '%s' '{"engine":"elevenlabs","elevenlabs":{}}' > "$HOME/.config/code-notify/tts.json"
export CURL_LOG="$test_dir/curl.log"
export SPEECH_LOCK_TEST_DIR="$lock_dir"
cat > "$stub_bin/curl" <<'STUB'
#!/bin/bash
out=""
prev=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    prev="$arg"
done
if [[ -d "$SPEECH_LOCK_TEST_DIR" ]]; then
    echo "lock-held-during-synthesis" >> "$CURL_LOG"
fi
echo "curl-called" >> "$CURL_LOG"
[[ -n "${CURL_DELAY:-}" ]] && sleep "$CURL_DELAY"
if [[ -n "${CURL_FAIL:-}" ]]; then
    [[ -n "$out" ]] && printf '{"detail":{"message":"quota exhausted"}}' > "$out"
    printf '500'
    exit 0
fi
[[ -n "$out" ]] && printf 'FAKE-AUDIO' > "$out"
printf '200'
STUB
chmod +x "$stub_bin/curl"
play_sound_sync() { echo "play_sync $1" >> "$SAY_LOG"; }

: > "$SAY_LOG"
: > "$CURL_LOG"
speak_notification "cloud voice message" "TestVoice" "proj"
grep -q "curl-called" "$CURL_LOG" || fail "elevenlabs synthesis should have run"
if grep -q "lock-held-during-synthesis" "$CURL_LOG"; then
    fail "synthesis must not run while the speech lock is held"
fi
grep -q "play_sync" "$SAY_LOG" || fail "prefetched audio should be played under the lock"
[[ ! -d "$lock_dir" ]] || fail "lock should be released after playback"
pass "synthesis runs before the lock, playback under it"

: > "$CURL_LOG"
tts_elevenlabs_ensure_cached "cloud voice message" "proj" > /dev/null ||
    fail "ensure_cached should succeed straight from the cache"
if grep -q "curl-called" "$CURL_LOG"; then
    fail "a cached phrase must not call the API again"
fi
pass "cached phrase skips the API call"

# --- Simultaneous identical cache-miss phrases must synthesize ONCE: the
# fill lock serializes the fills, and the losers reuse the winner's cache
# entry instead of each issuing their own API call.
: > "$SAY_LOG"
: > "$CURL_LOG"
export CURL_DELAY=0.5
speak_notification "burst phrase" "TestVoice" "proj" &
speak_notification "burst phrase" "TestVoice" "proj" &
speak_notification "burst phrase" "TestVoice" "proj" &
wait
unset CURL_DELAY
curl_calls=$(grep -c "curl-called" "$CURL_LOG" || true)
[[ "$curl_calls" == "1" ]] || fail "identical concurrent phrases should synthesize once, got $curl_calls API calls"
play_calls=$(grep -c "play_sync" "$SAY_LOG" || true)
[[ "$play_calls" == "1" ]] || fail "identical concurrent phrases should play once, got $play_calls"
pass "concurrent identical cache misses synthesize once"

# --- A failed synthesis must leave TTS_LAST_ERROR readable in THIS shell
# (`cn voice elevenlabs test` reports it): the cache preparation must not run
# in a command-substitution subshell that would discard it.
TTS_LAST_ERROR=""
if CURL_FAIL=1 tts_elevenlabs_speak "error phrase" "proj"; then
    fail "synthesis should fail when the API returns an error"
fi
[[ "$TTS_LAST_ERROR" == *"quota exhausted"* ]] ||
    fail "TTS_LAST_ERROR should carry the API error, got: '$TTS_LAST_ERROR'"
pass "API error survives cache preparation"

# --- A fill lock abandoned by a killed filler is aged out and the phrase
# still synthesizes (conditional reclaim: the observed expired stamp is
# re-verified under the reclaim mutex before removal).
: > "$CURL_LOG"
stale_key="$(tts_cache_key "stale fill phrase" "$(tts_elevenlabs_voice_id)" "$(tts_elevenlabs_model_id)" "proj")"
stale_cache="$(tts_cache_path "$stale_key" "proj")"
mkdir -p "${stale_cache}.fill"
printf '%s' "$(( $(date +%s) - 3600 ))" > "${stale_cache}.fill/stamp"
tts_elevenlabs_ensure_cached "stale fill phrase" "proj" ||
    fail "an abandoned fill lock should be reclaimed"
[[ -s "$stale_cache" ]] || fail "the phrase should have been synthesized after reclaim"
curl_calls=$(grep -c "curl-called" "$CURL_LOG" || true)
[[ "$curl_calls" == "1" ]] || fail "expected exactly one synthesis after reclaim, got $curl_calls"
pass "abandoned fill lock is reclaimed"

# --- The fill reclaim must refuse when the lock no longer holds the stamp
# that was judged expired: by the time a delayed waiter acts, the lock may
# belong to a NEW filler, and removing it would allow duplicate synthesis.
fresh_lock="$test_dir/fresh.fill"
old_stamp="$(( $(date +%s) - 3600 ))"
mkdir -p "$fresh_lock"
printf '%s' "$(date +%s)" > "$fresh_lock/stamp"
if tts_fill_lock_reclaim "$fresh_lock" "$old_stamp"; then
    fail "reclaim must refuse when the fill stamp changed since it was judged"
fi
[[ -d "$fresh_lock" ]] || fail "a re-stamped (live) fill lock must survive a delayed reclaimer"
rm -rf "$fresh_lock"
pass "fill reclaim refuses when a new filler owns the lock"

# --- While another reclaimer holds the fill reclaim mutex, a second
# reclaimer must back off without touching the lock.
busy_lock="$test_dir/busy.fill"
mkdir -p "$busy_lock" "$busy_lock.reclaim"
printf '%s' "$old_stamp" > "$busy_lock/stamp"
printf '%s' "$(date +%s)" > "$busy_lock.reclaim/stamp"
if tts_fill_lock_reclaim "$busy_lock" "$old_stamp"; then
    fail "reclaim must back off while the reclaim mutex is held"
fi
[[ -d "$busy_lock" ]] || fail "the fill lock must be untouched while the mutex is busy"
rm -rf "$busy_lock" "$busy_lock.reclaim"
pass "fill reclaim backs off while the mutex is busy"

# --- A reclaim mutex abandoned by a killed reclaimer must not wedge fill
# reclamation forever: waiters age it out and the phrase still synthesizes.
: > "$CURL_LOG"
wedge_key="$(tts_cache_key "wedged fill phrase" "$(tts_elevenlabs_voice_id)" "$(tts_elevenlabs_model_id)" "proj")"
wedge_cache="$(tts_cache_path "$wedge_key" "proj")"
mkdir -p "${wedge_cache}.fill" "${wedge_cache}.fill.reclaim"
printf '%s' "$old_stamp" > "${wedge_cache}.fill/stamp"
printf '%s' "$old_stamp" > "${wedge_cache}.fill.reclaim/stamp"
tts_elevenlabs_ensure_cached "wedged fill phrase" "proj" ||
    fail "an abandoned reclaim mutex should be aged out"
[[ -s "$wedge_cache" ]] || fail "the phrase should synthesize after the dead reclaimer's mutex is cleared"
curl_calls=$(grep -c "curl-called" "$CURL_LOG" || true)
[[ "$curl_calls" == "1" ]] || fail "expected exactly one synthesis after mutex ageout, got $curl_calls"
pass "dead reclaimer's fill mutex is cleared"

# --- A failed synthesis must suppress identical retries for the backoff
# window: during an outage or invalid-key period, a burst of identical
# events would otherwise repeat the same doomed request once per event.
: > "$CURL_LOG"
TTS_LAST_ERROR=""
if CURL_FAIL=1 tts_elevenlabs_ensure_cached "doomed phrase" "proj"; then
    fail "synthesis should fail when the API returns an error"
fi
if tts_elevenlabs_ensure_cached "doomed phrase" "proj"; then
    fail "a phrase should stay failed during the backoff window"
fi
curl_calls=$(grep -c "curl-called" "$CURL_LOG" || true)
[[ "$curl_calls" == "1" ]] || fail "the backed-off retry must not call the API, got $curl_calls calls"
[[ "$TTS_LAST_ERROR" == *"quota exhausted"* ]] ||
    fail "a backed-off caller should report the recorded error, got: '$TTS_LAST_ERROR'"
pass "failed synthesis backs off instead of retrying"

# --- A concurrent identical burst during an outage makes ONE request total:
# the fill-lock winner fails and records the marker before releasing, so no
# waiter can slip in and repeat the request.
: > "$CURL_LOG"
doomed_key="$(tts_cache_key "doomed burst" "$(tts_elevenlabs_voice_id)" "$(tts_elevenlabs_model_id)" "proj")"
doomed_cache="$(tts_cache_path "$doomed_key" "proj")"
CURL_FAIL=1 tts_elevenlabs_ensure_cached "doomed burst" "proj" &
CURL_FAIL=1 tts_elevenlabs_ensure_cached "doomed burst" "proj" &
CURL_FAIL=1 tts_elevenlabs_ensure_cached "doomed burst" "proj" &
wait
curl_calls=$(grep -c "curl-called" "$CURL_LOG" || true)
[[ "$curl_calls" == "1" ]] || fail "a failing identical burst should make one request, got $curl_calls"
[[ ! -s "$doomed_cache" ]] || fail "a failed burst must not leave a cache entry"
pass "failing identical burst makes one request"

# --- The backoff is short-lived: an expired marker allows a fresh attempt,
# and CODE_NOTIFY_TTS_FAIL_BACKOFF_SECONDS=0 disables the backoff entirely.
: > "$CURL_LOG"
printf '%s\nold failure' "$(( $(date +%s) - 3600 ))" > "${doomed_cache}.fail"
tts_elevenlabs_ensure_cached "doomed burst" "proj" ||
    fail "an expired failure marker should allow a retry"
[[ -s "$doomed_cache" ]] || fail "the retry after backoff expiry should fill the cache"
[[ ! -f "${doomed_cache}.fail" ]] || fail "a successful fill should clear the failure marker"
if ! CODE_NOTIFY_TTS_FAIL_BACKOFF_SECONDS=0 \
    CURL_FAIL=1 tts_elevenlabs_ensure_cached "doomed phrase" "proj" 2>/dev/null; then
    :
fi
curl_calls=$(grep -c "curl-called" "$CURL_LOG" || true)
[[ "$curl_calls" == "2" ]] || fail "backoff 0 should retry immediately, got $curl_calls total calls"
pass "failure backoff expires and can be disabled"
disable_speech_queue

echo ""
echo "All speech queue tests passed"
