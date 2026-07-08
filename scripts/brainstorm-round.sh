#!/bin/bash
# brainstorm-round.sh — run one real round of a git-native multi-agent brainstorm.
#
# Usage:
#   ./scripts/brainstorm-round.sh <topic> <brief-file> <participant> [participant ...]
#
# Example:
#   ./scripts/brainstorm-round.sh demo-topic brief.md kimi glm mmx
#
# The script uses the real orchestrator.sh primitives (spawn, send, tick,
# remember, recall, fleet) and invokes the real external AI CLI tools for each
# participant. Every brief and response becomes a committed git object in the
# agent repos, so the full round is auditable via `git log`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ORCHESTRATOR="$BASE_DIR/orchestrator.sh"

if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <topic> <brief-file> <participant> [participant ...]" >&2
    echo "Example: $0 demo-topic brief.md kimi glm mmx" >&2
    exit 1
fi

TOPIC="$1"
BRIEF_FILE="$2"
shift 2
PARTICIPANTS=("$@")

if [ ! -f "$BRIEF_FILE" ]; then
    echo "Error: brief file not found: $BRIEF_FILE" >&2
    exit 1
fi

BRIEF="$(cat "$BRIEF_FILE")"

# ---------------------------------------------------------------------------
# Helper: invoke the real external AI CLI for a participant.
# ---------------------------------------------------------------------------
invoke_participant() {
    local participant="$1"
    local prompt="$2"

    case "$participant" in
        kimi)
            kimi -p "$prompt"
            ;;
        glm)
            # `--` is required: opencode (yargs) treats a positional message
            # starting with `-` as an unknown flag. kimi does NOT get this:
            # `kimi -p -- "$prompt"` breaks under commander.js while
            # `kimi -p "$prompt"` already handles dash-leading values. See
            # BRAINSTORM_WIRING_NOTES.md for the tested rationale.
            opencode run -m zai-coding-plan/glm-5.2 --dangerously-skip-permissions -- "$prompt"
            ;;
        mmx)
            mmx text chat --message "$prompt" --output text
            ;;
        *)
            echo "Error: unknown participant '$participant' (no external tool configured)" >&2
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Setup: ensure coordinator and all participants exist.
# ---------------------------------------------------------------------------
if [ ! -d "$BASE_DIR/agents/coordinator" ]; then
    "$ORCHESTRATOR" spawn coordinator coordinator
fi

for participant in "${PARTICIPANTS[@]}"; do
    if [ ! -d "$BASE_DIR/agents/$participant" ]; then
        "$ORCHESTRATOR" spawn "$participant" worker
    fi
done

# ---------------------------------------------------------------------------
# Dispatch: send the brief from coordinator to each participant's inbox.
# Verify the message actually lands as a real committed file before continuing.
# ---------------------------------------------------------------------------
echo "[brainstorm] dispatching brief '$TOPIC' to participants: ${PARTICIPANTS[*]}"
for participant in "${PARTICIPANTS[@]}"; do
    "$ORCHESTRATOR" send coordinator "$participant" "$BRIEF"

    if ! ls "$BASE_DIR/agents/$participant/inbox/"*.md >/dev/null 2>&1; then
        echo "Error: brief did not land in $participant inbox" >&2
        exit 1
    fi
    echo "[brainstorm] verified inbox file for $participant"
done

# ---------------------------------------------------------------------------
# Thinking + real tool invocation + recording.
# For each participant:
#   1. tick the agent (processes inbox, moves message to .processed-*).
#   2. read the original message content from the processed file.
#   3. invoke the real external AI CLI tool and capture stdout.
#   4. overwrite the agent's outbox response with the real captured output.
#   5. send_message the real response back to coordinator's inbox.
#   6. remember it under round-<topic>-<participant> so recall works later.
# ---------------------------------------------------------------------------
for participant in "${PARTICIPANTS[@]}"; do
    echo "[brainstorm] processing participant: $participant"

    "$ORCHESTRATOR" tick "$participant"

    # Find the message this tick just processed.
    processed=("$BASE_DIR/agents/$participant/inbox/.processed-"*.md)
    if [ ! -f "${processed[0]:-}" ]; then
        echo "Error: no processed message found for $participant" >&2
        exit 1
    fi
    # If multiple processed files exist, use the newest one.
    processed_file="$(ls -t "$BASE_DIR/agents/$participant/inbox/.processed-"*.md | head -n1)"
    msg_name="$(basename "$processed_file" | sed 's/^\.processed-//')"

    # Extract the original message body. The message header is the last field,
    # so we grab it and everything that follows.
    prompt="$(awk '/^message: / { sub(/^message: /, ""); found=1 } found { print }' "$processed_file")"

    echo "[brainstorm] invoking real tool for $participant..."
    response="$(invoke_participant "$participant" "$prompt")"

    # Overwrite the simulated outbox response with the real one.
    # Use printf to avoid shell expansion of response content that may contain
    # backticks, $(...), ${...}, etc.
    {
        printf 'from: %s\n' "$participant"
        printf 'to: %s\n' "coordinator"
        printf 'timestamp: %s\n' "$(date -Iseconds)"
        printf 'in_reply_to: %s\n' "$msg_name"
        printf 'result: %s\n' "$response"
    } > "$BASE_DIR/agents/$participant/outbox/$msg_name"

    (
        cd "$BASE_DIR/agents/$participant"
        git add -A
        git commit -m "real response: $participant → coordinator ($msg_name)" -q
    )

    # Send the real response back to the coordinator's inbox.
    "$ORCHESTRATOR" send "$participant" coordinator "$response"

    # Remember it so it is queryable later via recall.
    "$ORCHESTRATOR" remember "$participant" "round-${TOPIC}-${participant}" "$response"

done

# ---------------------------------------------------------------------------
# Archive a human-readable transcript into the main repo so the round is not
# only in the nested agent repos but also leaves a durable artifact here.
# ---------------------------------------------------------------------------
ROUND_DIR="$BASE_DIR/rounds/$TOPIC"
mkdir -p "$ROUND_DIR"

{
    echo "# Brainstorm round: $TOPIC"
    echo ""
    echo "started: $(date -Iseconds)"
    echo "participants: ${PARTICIPANTS[*]}"
    echo ""
    echo "## Brief"
    echo ""
    echo "\`\`\`"
    echo "$BRIEF"
    echo "\`\`\`"
    echo ""

    for participant in "${PARTICIPANTS[@]}"; do
        echo "## Participant: $participant"
        echo ""
        echo "Agent repo history:"
        echo ""
        echo "\`\`\`"
        git -C "$BASE_DIR/agents/$participant" log --oneline
        echo "\`\`\`"
        echo ""
        echo "Captured response (also remembered as \`round-${TOPIC}-${participant}\`):"
        echo ""
        echo "\`\`\`"
        "$ORCHESTRATOR" recall "$participant" "round-${TOPIC}-${participant}"
        echo "\`\`\`"
        echo ""
    done
} > "$ROUND_DIR/transcript.md"

# ---------------------------------------------------------------------------
# Commit the transcript into the main repo so the round leaves a durable,
# cloneable record here (not only in the nested agent repos) — fulfilling
# the "durable, cloneable record" claim in this script's header comment,
# which was previously only true because a human ran `git commit` by hand
# after each of the first two rounds.
#
# Re-runs that happen to produce byte-identical content must be a no-op
# rather than a crash: `git commit` returns nonzero when there is nothing
# to commit, which under `set -euo pipefail` would terminate the script.
# We check the staged tree first and only commit when there is a real diff.
# ---------------------------------------------------------------------------
git -C "$BASE_DIR" add "rounds/$TOPIC/transcript.md"
if git -C "$BASE_DIR" diff --cached --quiet -- "rounds/$TOPIC/transcript.md"; then
    echo "[brainstorm] transcript unchanged for '$TOPIC' (nothing to commit)"
else
    git -C "$BASE_DIR" commit -m "round: $TOPIC completed ($(date -Iseconds))" -q
    echo "[brainstorm] committed transcript to main repo: rounds/$TOPIC/transcript.md"
fi

# ---------------------------------------------------------------------------
# Output: fleet status and pointers to the history.
# ---------------------------------------------------------------------------
echo ""
"$ORCHESTRATOR" fleet

echo ""
echo "[brainstorm] round '$TOPIC' complete."
echo "  - Per-agent git history: git log --all --oneline -- agents/coordinator agents/${PARTICIPANTS[*]}"
echo "  - Main repo transcript:  rounds/$TOPIC/transcript.md"
