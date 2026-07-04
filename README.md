# Git-Native Agents

A **multi-agent orchestration system** built entirely on git primitives — agents live in separate git repositories, communicate by writing to each other's `inbox/` directories, store memories as tagged commits, and coordinate through merge-based consensus.

## Why It Matters

Multi-agent systems typically require a central scheduler, message broker, and shared database. This system replaces all three with git: each agent is a repository, messages are files committed to the recipient's inbox, and coordination is a git merge. The result is a fully distributed, auditable, fault-tolerant agent fleet with zero external dependencies. Every message leaves a permanent commit trail. Every decision is a merge commit. Thought branches provide isolated speculative execution with clean rollback (just delete the branch). The system is intended for small fleets; it has not been benchmarked at scale, and a broker-based architecture is likely more appropriate once message-routing overhead becomes noticeable.

## How It Works

**Agent lifecycle**: Each agent is initialized via `spawn {name} {role}` which runs `git init` in `agents/{name}/` and creates an `AGENT.yaml` manifest recording name, role, spawn time, tick count, and status. The repository structure:

```
agents/{name}/
├── AGENT.yaml          # Metadata: name, role, tick, status
├── inbox/              # Incoming messages (*.md files)
├── outbox/             # Responses to processed messages
├── memory/             # Key-value storage (*.txt files)
└── thought-{topic}.md  # Thought artifacts on branches
```

**Message protocol**: `send {from} {to} {msg}` writes a structured Markdown file to the recipient's `inbox/` directory. The file contains YAML-like headers (from, to, timestamp, message). The sender commits this to the *recipient's* repository.

**Tick processing**: `tick {name}` scans the agent's `inbox/` for `*.md` files. Each message is processed (simulated computation), a response is written to `outbox/`, and the original message is moved to `inbox/.processed-*`. The tick counter in `AGENT.yaml` is incremented and a commit records the batch.

**Memory**: `remember {agent} {key} {value}` writes to `memory/{key}.txt`, commits, and creates a git tag `memory/{key}`. Recall is `git show memory/{key}:memory/{key}.txt`.

**Thought branches**: `think {agent} {topic}` creates a `thought/{topic}` branch for speculative exploration. `decide {agent} {topic}` merges it back. This mirrors how human teams use draft documents — work happens on a branch, decisions are merges.

**Broadcast**: `broadcast {from} {msg}` iterates all registered agents and sends the message to each (except the sender). O(N) in fleet size.

**Fleet status**: `fleet` displays a summary table — each agent's name, role, tick count, commit count, inbox depth, memory count, and active thought branches.

| Git Primitive | Agent Concept | O(?) |
|---------------|---------------|------|
| `inbox/*.md` | Message queue | O(1) enqueue, O(n) scan |
| `outbox/*.md` | Response queue | O(1) enqueue |
| `memory/*.txt` + `git tag` | Key-value memory | O(1) lookup by tag |
| `thought/*` branches | Parallel exploration | O(1) create/merge |
| `AGENT.yaml` | Agent metadata | O(1) read/write |
| Git commits | Auditable state log | O(n) history scan |

## Quick Start

```bash
# Spawn a fleet
./orchestrator.sh spawn "architect" "coordinator"
./orchestrator.sh spawn "builder" "worker"
./orchestrator.sh spawn "analyst" "analyst"

# Send messages
./orchestrator.sh send "architect" "builder" "build topological-sort with 15 tests"

# Process inboxes
./orchestrator.sh tick "builder"

# Store and recall memories
./orchestrator.sh remember "analyst" "fleet_size" "589 repos"
./orchestrator.sh recall "analyst" "fleet_size"

# View fleet status
./orchestrator.sh fleet
```

## API

| Command | Description |
|---------|-------------|
| `spawn [name] [role]` | Initialize a new agent repository |
| `send [from] [to] [msg]` | Point-to-point message |
| `tick [agent]` | Process one agent's inbox |
| `remember [agent] [key] [value]` | Store a tagged memory |
| `recall [agent] [key]` | Retrieve a tagged memory |
| `think [agent] [topic]` | Create a thought branch |
| `decide [agent] [topic]` | Merge a thought branch to main |
| `fleet` | Display all agents' status |
| `broadcast [from] [msg]` | Send to all agents |

## Architecture Notes

Git-Native Agents extends the single-agent model (git-agent-system) to multi-agent orchestration. Each agent is fully autonomous — no central scheduler, no shared state beyond git. The system is well-suited for long-running reasoning tasks where audit trails matter. In **γ + η = C**, this architecture pushes everything toward η: git handles all coordination reflexively. See [Architecture](https://github.com/SuperInstance/SuperInstance/blob/main/ARCHITECTURE.md).

## References

- Hewitt, C. "Viewing Control Structures as Patterns of Passing Messages," MIT AI Memo 410 (1976).
- Dias, V. et al. "Git as a Distributed Database," IEEE Software (2022).
- Brown, A. *The Architecture of Open Source Applications*, Vol. III: "Git." (2016).

## License

MIT
