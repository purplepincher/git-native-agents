#!/usr/bin/env bash
# Concurrency tests for git-native-agents.
# These tests exercise the exact races that previously caused crashes:
# concurrent sends to one recipient and concurrent ticks on one agent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

pass() {
    echo "PASS: $1"
}

# Count files in a directory matching a glob, returning 0 when nothing matches.
# Optional third argument is an exclusion glob.
count_files() {
    local dir="$1"
    local pattern="$2"
    local exclude="${3:-}"
    if [ -n "$exclude" ]; then
        find "$dir" -maxdepth 1 -type f -name "$pattern" ! -name "$exclude" 2>/dev/null | wc -l
    else
        find "$dir" -maxdepth 1 -type f -name "$pattern" 2>/dev/null | wc -l
    fi
}

# Verify prerequisites.
command -v flock >/dev/null 2>&1 || fail "flock is required but not installed"
command -v git >/dev/null 2>&1 || fail "git is required but not installed"

# Run in a throwaway copy so failures do not pollute the project tree.
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

cp "$PROJECT_DIR/orchestrator.sh" "$TEST_DIR/orchestrator.sh"
chmod +x "$TEST_DIR/orchestrator.sh"
cd "$TEST_DIR"

ORCH="$TEST_DIR/orchestrator.sh"

echo "==> Test setup: spawning agents"
"$ORCH" spawn "architect" "coordinator"
"$ORCH" spawn "builder" "worker"
"$ORCH" spawn "analyst" "analyst"

# ---------------------------------------------------------------------------
# Test 1: concurrent sends to a single recipient must not crash and must
# deliver every message.
# ---------------------------------------------------------------------------
echo "==> Test 1: 12 concurrent sends to one recipient"
N_SENDS=12
pids=()
for i in $(seq 1 "$N_SENDS"); do
    "$ORCH" send "architect" "builder" "concurrent message $i" &
    pids+=("$!")
done

send_failures=0
for pid in "${pids[@]}"; do
    wait "$pid" || send_failures=$((send_failures + 1))
done

inbox_count="$(count_files "$TEST_DIR/agents/builder/inbox" "*.md")"
echo "    Sends failed: $send_failures"
echo "    Inbox count:  $inbox_count"

[ "$send_failures" -eq 0 ] || fail "concurrent sends crashed ($send_failures failures)"
[ "$inbox_count" -eq "$N_SENDS" ] || fail "expected $N_SENDS messages, found $inbox_count"
pass "concurrent sends delivered all $N_SENDS messages without crashing"

# ---------------------------------------------------------------------------
# Test 2: concurrent ticks on one agent must not crash and must eventually
# process every message exactly once.
# ---------------------------------------------------------------------------
echo "==> Test 2: concurrent ticks on one agent"
N_TICKS=5
pids=()
for _ in $(seq 1 "$N_TICKS"); do
    "$ORCH" tick "builder" &
    pids+=("$!")
done

tick_failures=0
for pid in "${pids[@]}"; do
    wait "$pid" || tick_failures=$((tick_failures + 1))
done

# After ticks complete, no *.md messages should remain in inbox.
# Exclude hidden .processed-* files; find's '*.md' matches them otherwise.
remaining="$(count_files "$TEST_DIR/agents/builder/inbox" "*.md" ".*")"
processed="$(count_files "$TEST_DIR/agents/builder/inbox" ".processed-*.md")"
tick_count="$(grep '^tick:' "$TEST_DIR/agents/builder/AGENT.yaml" | cut -d' ' -f2)"

echo "    Ticks failed:   $tick_failures"
echo "    Remaining:      $remaining"
echo "    Processed:      $processed"
echo "    Tick counter:   $tick_count"

[ "$tick_failures" -eq 0 ] || fail "concurrent ticks crashed ($tick_failures failures)"
[ "$remaining" -eq 0 ] || fail "expected 0 remaining messages, found $remaining"
[ "$processed" -eq "$N_SENDS" ] || fail "expected $N_SENDS processed messages, found $processed"
[ "$tick_count" -ge 1 ] || fail "tick counter did not advance"
pass "concurrent ticks processed all messages without crashing"

# ---------------------------------------------------------------------------
# Test 3: concurrent spawn of the same agent must not create duplicate
# registrations or corrupt the registry.
# ---------------------------------------------------------------------------
echo "==> Test 3: concurrent duplicate spawns are rejected safely"
N_SPAWNS=5
pids=()
for _ in $(seq 1 "$N_SPAWNS"); do
    "$ORCH" spawn "racer" "worker" &
    pids+=("$!")
done

spawn_success=0
spawn_fail=0
for pid in "${pids[@]}"; do
    if wait "$pid"; then
        spawn_success=$((spawn_success + 1))
    else
        spawn_fail=$((spawn_fail + 1))
    fi
done

reg_count="$(grep -c 'agents/racer' "$TEST_DIR/registry/agents.txt" 2>/dev/null || echo 0)"
echo "    Spawn success:  $spawn_success"
echo "    Spawn failures: $spawn_fail"
echo "    Registry refs:  $reg_count"

[ "$spawn_success" -eq 1 ] || fail "expected exactly one successful spawn, got $spawn_success"
[ "$spawn_fail" -eq $((N_SPAWNS - 1)) ] || fail "expected $((N_SPAWNS - 1)) failed spawns, got $spawn_fail"
[ "$reg_count" -eq 1 ] || fail "expected one registry entry, found $reg_count"
pass "concurrent duplicate spawns serialized correctly"

# ---------------------------------------------------------------------------
# Test 4: mixed concurrent send and tick on one agent.
# ---------------------------------------------------------------------------
echo "==> Test 4: mixed concurrent send/tick"
N_MIXED=8
pids=()
for i in $(seq 1 "$N_MIXED"); do
    "$ORCH" send "analyst" "builder" "mixed message $i" &
    pids+=("$!")
    "$ORCH" tick "builder" &
    pids+=("$!")
done

mixed_failures=0
for pid in "${pids[@]}"; do
    wait "$pid" || mixed_failures=$((mixed_failures + 1))
done

[ "$mixed_failures" -eq 0 ] || fail "mixed concurrent send/tick crashed ($mixed_failures failures)"
pass "mixed concurrent send/tick completed without crashing"

echo ""
echo "All concurrency tests passed."
