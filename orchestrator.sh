#!/bin/bash
# git-native-agents: Multi-agent orchestration using git as the primitive
# Agents communicate via git branches, notes, and tags
# State machine: git objects. Messages: git notes. Memory: git tags.
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="$BASE_DIR/registry"
mkdir -p "$REGISTRY"

# flock is required to serialize concurrent operations on a shared git repo.
if ! command -v flock >/dev/null 2>&1; then
    echo "Error: 'flock' is required but not installed." >&2
    exit 1
fi

# Color output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log() { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
ok()  { echo -e "${GREEN}✓${NC} $1"; }
warn(){ echo -e "${YELLOW}!${NC} $1"; }
fail(){ echo -e "${RED}✗${NC} $1"; }

# Spawn a new agent
spawn_agent() {
    local name="$1"
    local role="${2:-worker}"
    local workspace="$BASE_DIR/agents/$name"
    local registry_lock="$REGISTRY/.lock"
    mkdir -p "$REGISTRY"
    
    # Serialize spawn operations to eliminate the check-then-act race when
    # two callers try to create the same agent or append to the registry.
    (
        flock -x 200 || { fail "Could not acquire spawn lock"; return 1; }
        
        if [ -d "$workspace" ]; then
            warn "Agent '$name' already exists"
            return 1
        fi
        
        mkdir -p "$workspace"
        git init -q "$workspace"
        cd "$workspace"
        git config user.name "$name"
        git config user.email "$name@git-agents.local"
        
        # Agent manifest
        cat > AGENT.yaml << EOF
name: $name
role: $role
spawned: $(date -Iseconds)
tick: 0
status: idle
workspace: $workspace
EOF
        
        mkdir -p inbox outbox memory
        
        git add -A
        git commit -m "spawn: agent $name ($role)" -q
        
        # Register
        echo "$workspace" >> "$REGISTRY/agents.txt"
        
        ok "Agent '$name' spawned as '$role'"
    ) 200>"$registry_lock"
}

# Send a message from one agent to another
send_message() {
    local from="$1"
    local to="$2"
    local msg="$3"
    
    local to_ws="$BASE_DIR/agents/$to"
    if [ ! -d "$to_ws" ]; then
        fail "Agent '$to' not found"
        return 1
    fi
    
    local lock_file="$to_ws/.agent.lock"
    
    # Serialize all writes (and the resulting git commit) to the recipient's
    # repo so concurrent sends do not race on .git/index.lock.
    (
        flock -x 200 || { fail "Could not acquire lock for '$to'"; return 1; }
        
        # Write message to recipient's inbox
        local msg_id="$(date +%s)-$RANDOM"
        cd "$to_ws"
        cat > "inbox/${msg_id}.md" << EOF
from: $from
to: $to
timestamp: $(date -Iseconds)
message: $msg
EOF
        git add -A
        git commit -m "msg: $from → $to: ${msg:0:50}" -q
        
        ok "Message sent: $from → $to"
    ) 200>"$lock_file"
}

# Process an agent's inbox (tick)
tick_agent() {
    local name="$1"
    local workspace="$BASE_DIR/agents/$name"
    
    if [ ! -d "$workspace" ]; then
        fail "Agent '$name' not found"
        return 1
    fi
    
    local lock_file="$workspace/.agent.lock"
    
    # Serialize the whole tick so the inbox scan, message moves, tick counter
    # update, and commit form one atomic unit. This removes the TOCTOU race
    # where two ticks see the same inbox state and the lost-update on tick.
    (
        flock -x 200 || { fail "Could not acquire lock for '$name'"; return 1; }
        cd "$workspace"
        
        # Build the inbox list under the lock so it cannot race with other
        # senders or tickers.
        local inbox_files=(inbox/*.md)
        local inbox_count=0
        local msg_file
        for msg_file in "${inbox_files[@]}"; do
            [ -f "$msg_file" ] || continue
            inbox_count=$((inbox_count + 1))
        done
        
        if [ "$inbox_count" -eq 0 ]; then
            warn "Agent '$name': inbox empty (idle)"
            return 0
        fi
        
        # Process each message
        for msg_file in inbox/*.md; do
            [ -f "$msg_file" ] || continue
            local msg_name=$(basename "$msg_file")
            local from=$(grep '^from:' "$msg_file" | head -1 | cut -d' ' -f2)
            local body=$(grep '^message:' "$msg_file" | cut -d' ' -f2-)
            
            log "Agent '$name' processing from '$from': ${body:0:40}..."
            
            # Generate response (simulated agent computation)
            local result="processed: ${body} → computed at $(date +%s)"
            cat > "outbox/${msg_name}" << EOF
from: $name
to: $from
timestamp: $(date -Iseconds)
in_reply_to: $msg_name
result: $result
EOF
            
            # Move to processed
            mv "$msg_file" "inbox/.processed-${msg_name}"
        done
        
        # Update tick count
        local tick=$(grep '^tick:' AGENT.yaml | cut -d' ' -f2)
        local new_tick=$((tick + 1))
        sed -i "s/^tick: .*/tick: $new_tick/" AGENT.yaml
        sed -i "s/^status: .*/status: working/" AGENT.yaml
        
        git add -A
        git commit -m "tick $new_tick: processed $inbox_count messages" -q
        
        ok "Agent '$name': tick $new_tick, processed $inbox_count messages"
    ) 200>"$lock_file"
}

# Agent creates a memory (git tag)
remember() {
    local name="$1"
    local key="$2"
    local value="$3"
    local workspace="$BASE_DIR/agents/$name"
    local lock_file="$workspace/.agent.lock"
    
    (
        flock -x 200 || { fail "Could not acquire lock for '$name'"; return 1; }
        cd "$workspace"
        mkdir -p memory
        echo "$value" > "memory/${key}.txt"
        git add -A
        # If the memory value is byte-identical to what is already committed
        # (e.g. a brainstorm round re-run produces the same response), there is
        # nothing to commit and `git commit` would exit nonzero — which under
        # `set -euo pipefail` would kill the calling script. Skip the commit
        # in that case; the existing commit already holds this exact value and
        # the tag refresh below keeps recall working.
        if git diff --cached --quiet; then
            warn "Agent '$name': memory '$key' unchanged (nothing to commit)"
        else
            git commit -m "remember: $key" -q
        fi
        git tag -f "memory/${key}" HEAD 2>/dev/null
        
        ok "Agent '$name' remembered: $key"
    ) 200>"$lock_file"
}

# Agent recalls a memory
recall() {
    local name="$1"
    local key="$2"
    local workspace="$BASE_DIR/agents/$name"
    
    cd "$workspace"
    if git show "memory/${key}:memory/${key}.txt" 2>/dev/null; then
        :
    else
        fail "Agent '$name' can't recall: $key"
    fi
}

# Create a thought branch
think() {
    local name="$1"
    local topic="$2"
    local workspace="$BASE_DIR/agents/$name"
    local lock_file="$workspace/.agent.lock"
    
    (
        flock -x 200 || { fail "Could not acquire lock for '$name'"; return 1; }
        cd "$workspace"
        local branch="thought/${topic}"
        git branch "$branch" 2>/dev/null || true
        git checkout "$branch" -q
        cat > "thought-${topic}.md" << EOF
# Thought: $topic
started: $(date -Iseconds)
agent: $name
status: exploring
EOF
        git add -A
        git commit -m "think: $topic" -q
        
        ok "Agent '$name' thinking about: $topic (branch: $branch)"
    ) 200>"$lock_file"
}

# Merge thought back
decide() {
    local name="$1"
    local topic="$2"
    local workspace="$BASE_DIR/agents/$name"
    local lock_file="$workspace/.agent.lock"
    
    (
        flock -x 200 || { fail "Could not acquire lock for '$name'"; return 1; }
        cd "$workspace"
        git checkout main -q 2>/dev/null || git checkout master -q
        git merge "thought/${topic}" -m "decide: merged $topic" -q 2>/dev/null || \
        git merge "thought/${topic}" -m "decide: merged $topic" --no-edit 2>/dev/null
        
        ok "Agent '$name' decided: $topic merged to main"
    ) 200>"$lock_file"
}

# Fleet status
fleet_status() {
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    echo -e "${CYAN}  GIT-NATIVE AGENT FLEET STATUS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
    
    if [ ! -f "$REGISTRY/agents.txt" ]; then
        warn "No agents registered"
        return
    fi
    
    local registry_lock="$REGISTRY/.lock"
    local agents=()
    # Read the registry under a shared lock; use a command group so the array
    # is populated in the current shell.
    {
        flock -s 200 || { fail "Could not acquire registry lock"; return 1; }
        while read -r workspace; do
            [ -d "$workspace" ] || continue
            agents+=("$workspace")
        done < "$REGISTRY/agents.txt"
    } 200<>"$registry_lock"
    
    local workspace
    for workspace in "${agents[@]}"; do
        cd "$workspace"
        local name=$(grep '^name:' AGENT.yaml | cut -d' ' -f2)
        local role=$(grep '^role:' AGENT.yaml | cut -d' ' -f2)
        local tick=$(grep '^tick:' AGENT.yaml | cut -d' ' -f2)
        local status=$(grep '^status:' AGENT.yaml | cut -d' ' -f2)
        local commits=$(git log --oneline | wc -l)
        local inbox=$(ls inbox/*.md 2>/dev/null | wc -l)
        local memories=$(ls memory/*.txt 2>/dev/null | wc -l)
        local branches=$(git branch | grep -c 'thought/' || echo "0")
        
        echo -e "  ${GREEN}$name${NC} ($role)"
        echo "    tick=$tick status=$status commits=$commits"
        echo "    inbox=$inbox memories=$memories thoughts=$branches"
    done
    
    echo -e "${CYAN}═══════════════════════════════════════${NC}"
}

# Broadcast to all agents
broadcast() {
    local from="$1"
    local msg="$2"
    local registry_lock="$REGISTRY/.lock"
    
    [ -f "$REGISTRY/agents.txt" ] || return
    
    # Snapshot the registry under lock so concurrent spawns cannot interleave
    # with the list of registered workspaces. Use a command group so the array
    # is populated in the current shell.
    local agents=()
    {
        flock -s 200 || { fail "Could not acquire registry lock"; return 1; }
        while read -r workspace; do
            [ -d "$workspace" ] || continue
            agents+=("$workspace")
        done < "$REGISTRY/agents.txt"
    } 200<>"$registry_lock"
    
    local workspace
    for workspace in "${agents[@]}"; do
        local to=$(cd "$workspace" && grep '^name:' AGENT.yaml | cut -d' ' -f2)
        [ "$to" = "$from" ] && continue
        send_message "$from" "$to" "$msg"
    done
}

case "${1:-help}" in
    spawn)    spawn_agent "${2:-agent-$(date +%s)}" "${3:-worker}" ;;
    send)     send_message "${2:?from}" "${3:?to}" "${4:?msg}" ;;
    tick)     tick_agent "${2:?agent}" ;;
    remember) remember "${2:?agent}" "${3:?key}" "${4:?value}" ;;
    recall)   recall "${2:?agent}" "${3:?key}" ;;
    think)    think "${2:?agent}" "${3:?topic}" ;;
    decide)   decide "${2:?agent}" "${3:?topic}" ;;
    fleet)    fleet_status ;;
    broadcast) broadcast "${2:?from}" "${3:?msg}" ;;
    help|*)
        echo "git-native-agents: Multi-agent orchestration via git primitives"
        echo "Commands: spawn, send, tick, remember, recall, think, decide, fleet, broadcast"
        ;;
esac
