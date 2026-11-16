---
name: plan-usage
description: Use when the user asks how much of their Claude Code, Codex or Cursor plan or subscription usage is used or left, when their usage limits or rate-limit windows reset, or whether they are close to hitting a usage cap.
---

# Plan usage

Shows how much of the user's Claude Code, Codex and Cursor plan is used and
when each limit resets, using the sign-ins those tools already store on this
machine.

## How to answer

1. Run the bundled script from this skill's directory:

   ```bash
   python3 -I scripts/usage.py
   ```

   Add `--only claude`, `--only codex`, `--only cursor` (or a comma list such
   as `--only claude,cursor`) when the user asks about specific tools.
   `-I` keeps Python from loading modules out of the current directory.

2. Reply with the script's numbers: each tool's plan, how much of each window
   is used, and when it resets. Lead with whichever window is closest to its
   limit. A "Not signed in" line means that tool isn't set up here; mention it
   only if the user asked about that tool.

3. If a tool shows `Couldn't check: …`, pass that sentence on as the answer
   for that tool. The fixes it names (run `claude` or `codex` in a terminal,
   open Cursor) are for the user to do; the script never refreshes sign-ins.

If the user asks what the script reads or sends, run
`python3 -I scripts/usage.py --explain` and show its output. It reads and
sends nothing.

## Credentials stay inside the script

The script is the only thing that touches the sign-ins. Never read them
yourself: no `security find-generic-password`, no `cat` or `jq` of
`~/.codex/auth.json` or `~/.claude/.credentials.json`, no `sqlite3` on
Cursor's `state.vscdb`, no hand-written `curl` to the usage endpoints. A token
that appears in your command or its output is sent into the conversation, and
a token in a command line is visible to every process on the machine. That
holds when the script fails too: report its message rather than debugging
around it.

| Thought | Instead |
|---|---|
| "The script failed, I'll just curl the endpoint myself" | Report the script's message. |
| "I'll check whether the token in the Keychain is expired" | The script already did; relay its hint. |
| "I'll run `claude` to refresh the token for them" | Tell the user to run it. |

## What the script guarantees

- Reads each sign-in read-only; never writes, refreshes, logs or copies it.
- Sends each token only to its own provider (`api.anthropic.com`,
  `chatgpt.com`, `cursor.com`) over verified HTTPS. URLs are hard-coded and
  redirects are refused.
- Prints only percentages, plan names and reset times. Error messages are
  fixed sentences, and tokens are scrubbed from output as a final check.
- Python standard library only, one file, no telemetry.

These usage endpoints are the ones each vendor's own apps use. They aren't
public APIs and can change; when one does, the script says the response
"has changed shape" instead of guessing.
