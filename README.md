# git-native-agents

Multi-agent orchestration script where each agent is a git repository. Agents communicate by committing files to each other's `inbox/`, store memories as git tags, and coordinate through merge commits.

## Requirements

- `git`
- `flock` (used to serialize concurrent operations on shared repos)
- Bash 4+

## Quickstart

```bash
git clone https://github.com/purplepincher/git-native-agents.git
cd git-native-agents

# Spawn a fleet
./orchestrator.sh spawn "architect" "coordinator"
./orchestrator.sh spawn "builder" "worker"

# Send a message and process it
./orchestrator.sh send "architect" "builder" "build topological-sort with 15 tests"
./orchestrator.sh tick "builder"

# Run the test suite
bash tests/run.sh
```

## Usage

### Spawn agents

```bash
./orchestrator.sh spawn "architect" "coordinator"
./orchestrator.sh spawn "builder" "worker"
./orchestrator.sh spawn "analyst" "analyst"
```

Output:

```text
✓ Agent 'architect' spawned as 'coordinator'
✓ Agent 'builder' spawned as 'worker'
✓ Agent 'analyst' spawned as 'analyst'
```

### Send and process messages

```bash
./orchestrator.sh send "architect" "builder" "build topological-sort with 15 tests"
./orchestrator.sh tick "builder"
```

Output:

```text
✓ Message sent: architect → builder
[11:31:44] Agent 'builder' processing from 'architect': build topological-sort with 15 tests...
✓ Agent 'builder': tick 1, processed 1 messages
```

`tick` scans `inbox/*.md`, writes a response to `outbox/`, moves the original message to `inbox/.processed-*`, increments the tick counter in `AGENT.yaml`, and commits the batch.

### Remember and recall

```bash
./orchestrator.sh remember "architect" "fleet_size" "589 repos"
./orchestrator.sh recall "architect" "fleet_size"
```

Output:

```text
✓ Agent 'architect' remembered: fleet_size
589 repos
```

`remember` stores the value in `memory/{key}.txt`, commits, and force-tags it as `memory/{key}`. `recall` reads it back with `git show`.

### Speculative work with thought branches

```bash
./orchestrator.sh think "architect" "refactor"
# ... do work on the thought/refactor branch ...
./orchestrator.sh decide "architect" "refactor"
```

Output:

```text
✓ Agent 'architect' thinking about: refactor (branch: thought/refactor)
✓ Agent 'architect' decided: refactor merged to main
```

### Broadcast to the fleet

```bash
./orchestrator.sh broadcast "architect" "sync status"
./orchestrator.sh tick "builder"
./orchestrator.sh tick "analyst"
```

Output:

```text
✓ Message sent: architect → builder
✓ Message sent: architect → analyst
[11:31:48] Agent 'builder' processing from 'architect': sync status...
✓ Agent 'builder': tick 2, processed 1 messages
[11:31:48] Agent 'analyst' processing from 'architect': sync status...
✓ Agent 'analyst': tick 1, processed 1 messages
```

### Fleet status

```bash
./orchestrator.sh fleet
```

Shows each agent's name, role, tick count, commit count, inbox depth, memory count, and active thought branches.

## How it works

- **Agent repo** — `spawn` runs `git init` in `agents/{name}/`, creates an `AGENT.yaml` manifest, and registers the workspace in `registry/agents.txt`.
- **Inbox** — `send {from} {to} {msg}` writes a Markdown file with YAML-like headers into the recipient's `inbox/` and commits it there.
- **Tick** — `tick {name}` processes every `*.md` in `inbox/`, writes a reply to `outbox/`, moves the message to `inbox/.processed-*`, updates `AGENT.yaml`, and commits.
- **Memory** — `remember` persists a key-value pair as `memory/{key}.txt` plus a `memory/{key}` tag. `recall` uses `git show memory/{key}:memory/{key}.txt`.
- **Thought branches** — `think` creates and checks out `thought/{topic}` with a `thought-{topic}.md` file. `decide` checks out `main` and merges the branch back.
- **Broadcast** — iterates the registry and sends to every agent except the sender.
- **Concurrency** — `flock` serializes writes to each repo and to the registry so concurrent `send`, `tick`, and `spawn` calls do not race on `.git/index.lock`.

## Command reference

| Command | Arguments | Description |
|---------|-----------|-------------|
| `spawn` | `[name] [role]` | Initialize a new agent repository |
| `send` | `[from] [to] [msg]` | Point-to-point message |
| `tick` | `[agent]` | Process the agent's inbox |
| `remember` | `[agent] [key] [value]` | Store a tagged memory |
| `recall` | `[agent] [key]` | Retrieve a tagged memory |
| `think` | `[agent] [topic]` | Create a `thought/{topic}` branch |
| `decide` | `[agent] [topic]` | Merge the thought branch into `main` |
| `broadcast` | `[from] [msg]` | Send a message to all other agents |
| `fleet` | — | Display fleet summary |
| `help` | — | List commands |

## Repository layout of an agent

```text
agents/{name}/
├── AGENT.yaml          # name, role, spawned time, tick count, status
├── inbox/              # incoming messages (*.md)
│   └── .processed-*    # handled messages
├── outbox/             # outgoing replies (*.md)
├── memory/             # tagged memories (*.txt)
└── thought-{topic}.md  # speculative notes on thought branches
```

## Limitations

- **No real message routing.** Broadcast is O(N) and every agent's inbox is a directory scan.
- **No encryption or authentication.** Repos are plain git; anyone with filesystem access can read or modify state.
- **No persistence beyond git.** History, messages, and memories are in the repo; host backup/restore is up to you.
- **Single-host or shared-filesystem.** Cross-machine fleets require a shared filesystem or manual repo synchronization.
- **Bash-only orchestration.** There is no API server or library; the interface is the `orchestrator.sh` command line.
- **Message processing is simulated by `orchestrator.sh tick` alone.** Real agent logic must be plugged in separately for that command — but `scripts/brainstorm-round.sh` does exactly this, overwriting the canned response with real output from an actual external AI CLI (kimi, opencode/GLM, or mmx) before recording it.
- **Not benchmarked at scale.** Designed for small fleets; a broker-based system is likely more appropriate for high message volumes.

## Adversarial code review disclosure (Item 6)

Per `purplepincher/purplepincher`'s graduation checklist Item 6, every bug
a cross-model adversarial review finds gets published here verbatim, not
softened or buried.

During a real adversarial review of `scripts/brainstorm-round.sh` — a
different model (deepseek-v4-pro, via aider) reviewing code that a
same-model sanity test had already passed — a real, serious bug was
found: the outbox response was written with an unquoted heredoc
(`<<EOF`). Any backtick, `$(...)`, or `${...}` present in a real AI
response would have been interpreted by the shell while writing the
response to disk.

**What could have gone wrong.** At best, this would silently corrupt the
recorded response the moment a real participant's answer contained a
backtick (routine in any response with code formatting). At worst, a
response containing a shell command inside backticks would have been
*executed*, not just recorded, in a subshell on the machine running the
round.

**Why the original test missed it.** The first, one-participant sanity
test used the prompt "What is 2 + 2 and why?" — a prompt that, by
construction, could never produce shell-active characters. The bug was
invisible to a same-process check because the check and the artifact
shared the same blind spot; it only surfaced once review crossed a real
model boundary.

**The fix.** The writer was converted to `printf '%s'` per field (commit
`acd74f1`). `printf '%s'` never re-interprets its argument as shell
syntax, so a response deliberately containing backticks is now written
out unexecuted and unmodified — verified with a real re-test using a
prompt engineered to produce backticks in the response.

This is this repository's first real instance of satisfying Item 6's
disclosure requirement.

## Testing

```bash
bash tests/run.sh
```

The test suite covers concurrent sends, concurrent ticks, duplicate spawns, and mixed send/tick races.

## License

MIT. See [`LICENSE`](./LICENSE).
