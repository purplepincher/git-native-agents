# Brainstorm Wiring Notes

`scripts/brainstorm-round.sh` wires `git-native-agents` to real external AI CLI
tools so a multi-participant brainstorm round is no longer a manual directory /
tmux/file-eyeballing exercise — it is a real, git-committed message-passing
round.

## What was built

- `scripts/brainstorm-round.sh` — a single runnable round.
- The script uses the **real** `orchestrator.sh` primitives as subprocess calls:
  `spawn_agent`, `send_message`, `tick_agent`, `remember`, and `fleet_status`.
- It invokes the real external tool for each participant:
  - `kimi -p "<prompt>"`
  - `opencode run -m zai-coding-plan/glm-5.2 --dangerously-skip-permissions "<prompt>"`
  - `mmx text chat --message "<prompt>" --output text`

## Real command to run a round

```bash
./scripts/brainstorm-round.sh <topic> <brief-file> <participant> [participant ...]
```

Example with all three participants:

```bash
./scripts/brainstorm-round.sh my-topic brief.md kimi glm mmx
```

Example with just the fastest participant for a quick sanity check:

```bash
echo "What is 2 + 2 and why?" > /tmp/test-brief.md
./scripts/brainstorm-round.sh verified-round /tmp/test-brief.md kimi
```

## What was actually tested end-to-end

A real round was run with one participant (`kimi`) and a one-sentence prompt:

```text
What is 2 + 2 and why?
```

The topic was `verified-round`. Verification performed:

1. **Agent repo is real:** `agents/kimi/` is a real git repo with real commits:

   ```text
   5e9e586 remember: round-verified-round-kimi
   dac59a4 real response: kimi → coordinator (1783469857-21322.md)
   a84343d tick 2: processed 1 messages
   8e850a2 msg: coordinator → kimi: What is 2 + 2 and why?
   ...
   2e785a7 spawn: agent kimi (worker)
   ```

2. **Message reached the inbox before the tick step:** the script checks for a
   real `.md` file in `agents/kimi/inbox/` immediately after `send_message`
   returns and before `tick_agent` is called.

3. **The subprocess actually ran:** the captured response is real `kimi` output
   (not a placeholder) and is substantively different from the input — it
   explains why 2 + 2 = 4 rather than echoing the question.

4. **Response recorded back to coordinator:** `agents/coordinator/inbox/` now
   contains the real response as a committed message from `kimi`.

5. **Response remembered and queryable:** `recall` returns the exact captured
   output:

   ```bash
   ./orchestrator.sh recall kimi round-verified-round-kimi
   ```

6. **Main repo artifact:** the script also wrote `rounds/verified-round/transcript.md`,
   which captures the agent repo history and the recalled response. This file is
   committed to the main repo so the round leaves a durable, cloneable record
   beyond the local agent repos.

## How the transcript is stored

- Each agent directory under `agents/` is a **standalone git repo** created by
  `orchestrator.sh`. The per-message commits (brief dispatch, tick, response,
  memory) live there, so `git -C agents/<name> log` shows the full granular
  history of that agent's round.
- `agents/*/` is ignored by the main repo because nested git repos cannot be
  committed as ordinary files. The main repo persists the script, registry,
  documentation, and the `rounds/<topic>/transcript.md` archive.

## Rough edges / not yet verified

- `glm` and `mmx` subprocess calls are implemented and map to the documented
  CLI invocations, but they were **not exercised end-to-end** in this session
  because the verification focused on the fastest path (`kimi`). They should be
  tested with real credentials/permissions before relying on them in a
  production round.
- The script assumes the external tools are on `$PATH` and that the environment
  (API keys, permissions, etc.) is already configured for them.
- Multi-line prompts and responses are preserved in `remember` and in the
  committed message files, but the coordinator's `inbox/*.md` format stores the
  response under a single `message:` header; downstream parsers should treat
  everything after `message:` as the payload.
- Concurrent rounds on the same topic/participant set have not been stress
  tested; `orchestrator.sh` uses `flock` per repo, which is reused here.
