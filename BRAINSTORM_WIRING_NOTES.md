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

## Argument hardening: briefs that start with `-` (verified)

A follow-up code review flagged that if a brief's content begins with a literal
`-` (e.g. `-1 is not the answer, but here's a real question: ...`), the
`$prompt` argument could be misread as a CLI flag by the underlying tool's
parser. This was tested for real against `kimi` and `opencode` (the `glm`
participant). The result is **tool-specific**, so the two branches were not
changed uniformly:

- **`opencode` (the `glm` participant) — real bug, now fixed.** `opencode run`
  uses `yargs`. Without protection, a positional message starting with `-` is
  treated as an unknown flag: the command prints the `run` subcommand help and
  exits `1`, so the round aborts at the `invoke_participant` step. Verified
  before/after:
  - Before: `opencode run -m zai-coding-plan/glm-5.2 --dangerously-skip-permissions "-1 is not the answer..."` → help text, exit `1`.
  - After:  `opencode run -m zai-coding-plan/glm-5.2 --dangerously-skip-permissions -- "-1 is not the answer..."` → real answer (`2+2 equals 4.`), exit `0`.
  - `yargs` natively honors `--` as end-of-options, so the trailing positional is
    delivered verbatim. The fix in `invoke_participant()` is the added `--`.
  - Confirmed end-to-end: `./scripts/brainstorm-round.sh dash-test-glm <dash-brief> glm` completes with exit `0` and the orchestrator log shows the full `-1 ...` prompt delivered to `glm`.

- **`kimi` — never a problem; deliberately left unchanged.** `kimi -p` is built
  on `commander.js`, which consumes a dash-leading value as the `-p` argument
  just fine. Verified directly and end-to-end:
  - `kimi -p "-1 is not the answer..."` → real answer quoting the prompt, exit `0`.
  - `./scripts/brainstorm-round.sh dash-test <dash-brief> kimi` → exit `0`, full prompt delivered.
  - Importantly, adding `--` to `kimi` is **not** safe and was **not** done:
    `kimi -p -- "<prompt>"` fails with `unknown command '<prompt>'` because
    `commander.js` treats the post-`--` token as a positional subcommand (and
    `kimi`'s top level has no positional command). So the two tools require
    different handling: `--` for `opencode`, plain quoting for `kimi`.

- **Regression check:** the plain non-dash path was re-run through the changed
  `glm` branch (`./scripts/brainstorm-round.sh plain-test-glm <plain-brief> glm`,
  brief `What is 2 + 2 and why? ...`) and still completes with exit `0`, so the
  added `--` does not disturb already-working prompts. `mmx` was out of the
  flagged scope and uses the same option-takes-value form as `kimi`
  (`--message "$prompt"`), which tested clean for `kimi`; it is left as-is.

The test rounds (`dash-test`, `dash-test-glm`, `plain-test-glm`) and their
agent repos / registry entries were ephemeral and were removed before
committing; only this note and the one-line `--` fix in
`scripts/brainstorm-round.sh` are committed.

## Rough edges / not yet verified

- `glm` is now exercised end-to-end (see the argument-hardening section above);
  `mmx` maps to the documented CLI invocation (`mmx text chat --message ...`)
  but was **not exercised end-to-end** in this session and should be tested with
  real credentials before relying on it in a production round.
- The script assumes the external tools are on `$PATH` and that the environment
  (API keys, permissions, etc.) is already configured for them.
- Multi-line prompts and responses are preserved in `remember` and in the
  committed message files, but the coordinator's `inbox/*.md` format stores the
  response under a single `message:` header; downstream parsers should treat
  everything after `message:` as the payload.
- Concurrent rounds on the same topic/participant set have not been stress
  tested; `orchestrator.sh` uses `flock` per repo, which is reused here.
