# DEEP_TRAJECTORY_aider.md

## 1. Structural gap between “ran once, verified” and “load‑bearing for the account”

The single clearest gap is that **a completed round is never automatically committed back into the main Git repository**.  

`scripts/brainstorm-round.sh` creates the per‑agent history and the final transcript file (`rounds/$TOPIC/transcript.md`), but it stops after printing the fleet status – it does **not** execute

```
git add rounds/$TOPIC/transcript.md
git commit -m "round: $TOPIC completed"
```

The transcript exists only as an untracked (or at best manually‑committed) file. If someone runs the script a second time for the same `TOPIC`, the file is overwritten with no prior Git record, losing the state of the previous round.  

Without an automatic commit, the main repository cannot **reliably** reconstruct what happened in a round without the nested agent repos (which are themselves ignored in the main repo’s `.gitignore`). This violates the project’s own principle that “the round leaves a durable, cloneable record beyond the local agent repos” (BRAINSTORM_WIRING_NOTES.md, §6).  

*Why `orchestrator.sh` alone doesn’t fix it*: the orchestrator’s `remember` primitive stores memories *inside* each agent’s own repo, but there is no primitive that records the **celebration of a round** into the main repo’s history. The script works around this by manually writing a markdown file, but it never ties that file into Git.

---

## 2. Real bug in the `glm` or `mmx` subprocess path

The `invoke_participant` function uses a heredoc to construct the outbox response after receiving the real tool’s output. The heredoc delimiter is **unquoted** in `scripts/brainstorm-round.sh`:

```bash
    cat > "$BASE_DIR/agents/$participant/outbox/$msg_name" <<EOF
from: $participant
to: coordinator
timestamp: $(date -Iseconds)
in_reply_to: $msg_name
result: $response
EOF
```

This means the shell will **expand** every backtick, `$()` command substitution, and `${}` variable reference that happens to appear inside `$response`.  

`$response` comes directly from the output of the external AI CLI (e.g. `kimi -p`, `opencode run`, `mmx text chat`). Real LLM output routinely contains shell‑significant characters such as:

- `${VAR}` (many code examples)
- backtick‑delimited code spans (`` `some command` ``)
- `$((...))` arithmetic expansions

If the LLM response includes a string like ``Error in function `${HOME}/config` : exit 0``, the unquoted heredoc would try to expand `${HOME}` and corrupt the outbox file. Even worse, an output containing `` `some_command` `` **would actually execute that command** in a subshell silently.  

This bug affects **all three tool paths** equally (it is executed for every participant), but the `kimi`‑only sanity‑check test (`“What is 2 + 2 and why?”`) never triggered it because the trivial prompt did not produce shell‑active characters. Once a participant submits a real‑world prompt (e.g. code, configuration snippets, or analysis) this bug **will** corrupt the recorded response and potentially execute arbitrary commands on the machine running the brainstorm.  

The exact line is in the `for participant ...` loop, after `response="$(invoke_participant ...)"`, in `brainstorm-round.sh`.

*Is the bug exclusive to the `glm` / `mmx` code path?*  
Formally no, but the question asks us to read the code for those two paths. The heredoc is shared infrastructure; it is the **most dangerous common fragility** that will surface as soon as either `glm` or `mmx` is used with a realistic prompt.

---

## 3. The single deepest, most consequential next real step

**Automatically commit the transcript into the main repo at the end of every round.**  

This can be accomplished by adding **three lines** to `scripts/brainstorm-round.sh` immediately after the transcript file is written:

```bash
git -C "$BASE_DIR" add rounds/$TOPIC/transcript.md
git -C "$BASE_DIR" commit -m "round: $TOPIC completed"
```

That alone converts the brainstorm script from “proven‑once tool” into a genuinely auditable instrument that records every completed round in the primary repository’s immutable history.  

It requires no new orchestrator primitives, no changes to the agent‑repo protocol, and no retrofitting of existing tests. It simply closes the current gap identified in question 1, making the tool **load‑bearing** because every real use leaves a non‑optional, reproducible trace in git.  

After this change, the account can look at `git log -- rounds/` and see every decision round it ever ran, exactly as the original design intended.

---

Conclusion: the most pressing structural gap is the missing Git commit of the transcript; the most dangerous code bug is the shell‑expanding heredoc that affects all paths; and the single smallest, highest‑leverage improvement is to commit the transcript automatically.
