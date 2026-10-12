#!/usr/bin/env bash
# Sourced by both Bash 3.2 and Bash 5. No pipeline/filter child owns guest output.
guest() {
    local phase="${2:-guest-$((GUEST_SEQUENCE+1))}" rc
    GUEST_SEQUENCE=$((GUEST_SEQUENCE+1))
    GUEST_RESULT="$WORK/guest-diagnostics/$phase/result.json"
    if ! mkdir -p "$WORK/guest-diagnostics/$phase" ||
       ! printf '%s\n' "$phase" > "$DSH_TEST_PHASE_FILE"; then
        GUEST_STATUS=125
        GUEST_FAILURES=$((GUEST_FAILURES+1))
        return 125
    fi
    if python3 "$HERE/guest-runner.py" run \
        --phase "$phase" --result "$GUEST_RESULT" \
        --timeout "$GUEST_TIMEOUT" --sample-after "${DSH_GUEST_SAMPLE_AFTER:-75}" \
        --initial-sample-after "${DSH_GUEST_INITIAL_SAMPLE_AFTER:-0}" \
        --events "$DSH_TEST_EVENT_LOG" --stdin-file "${3:-}" -- \
        "$ISH_BUILD/ish" -f "$WORK/fakefs" /bin/sh -c "$1"; then
        rc=0
    else
        rc=$?
        GUEST_FAILURES=$((GUEST_FAILURES+1))
        printf '[guest] FAIL phase=%s helper_exit=%s (see result.json)\n' "$phase" "$rc" >&2
    fi
    GUEST_STATUS=$rc
    return "$rc"
}

wrong_token() {
    # Same shortcut mock and same guest command as the historical failure.
    guest "export HOME=/root DEEPSEEK_API_KEY=test DEEPSEEK_BASE_URL=http://127.0.0.1:$MOCK_PORT \
       DSH_HOST_BRIDGE_URL=http://127.0.0.1:$BRIDGE_PORT DSH_HOST_BRIDGE_TOKEN=wrong-token; \
       cd /root/workspace; node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js --profile headless 'What device is this?'" \
       wrong-token > "$WORK/bridge-denied.txt"
    python3 "$HERE/check-bridge-refusal.py" --result "$GUEST_RESULT" \
        --output "$WORK/bridge-denied.txt" --events "$DSH_TEST_EVENT_LOG"
}
