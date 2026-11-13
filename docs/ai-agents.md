# AI agent work (Claude Code, Codex)

How time counts while an AI coding agent works for you, and how to connect an agent. [Back to the README](../README.md)

## How it works

When an AI coding agent is working on a task for you, that time can count as your work, even
while you are idle, the screen is locked or another app is in front. A reply that takes an hour
is an hour of work.

Detection is exact, not guessed: the agents' own hooks tell WorkPulse when a turn starts, when a
tool runs and when the turn ends. Each hook runs `agent-hook.sh`, which touches or removes an
empty marker file in `~/Library/Application Support/WorkPulse/agents/`. WorkPulse sees only that
a marker exists and when it was last touched. It never reads prompts, transcripts or output.

- Agent time is recorded as Work with the application "Claude Code" or "Codex" and the source
  "AI agent".
- Your own work in a work app keeps its own application. Agent work fills in only where your own
  activity is not already work (idle, locked, non-work or ignored app), so nothing counts twice.
- Pause and sleep still record nothing, and in the Personal profile agent time is not counted.
- If an agent is interrupted or crashes it cannot say it stopped. After 15 minutes without any
  hook signal (Settings › AI agents) the session is ended at the last signal, not at the time it
  was noticed.
- Only tools with hooks are covered: Claude Code (terminal and the desktop app's Code tab) and
  Codex (CLI and the ChatGPT app's Codex). Plain chat has no hooks and is not detected.

Setup. Settings › AI agents shows each agent as Connected (with the time of its last signal) or
Not connected. "Setup steps…" can add the hook entries for you: it keeps a copy of the
configuration file next to it (`….workpulse-backup`), adds only its own entries and can undo them.
To do it by hand: WorkPulse keeps the script at
`~/Library/Application Support/WorkPulse/agent-hook.sh`.

Claude Code, in `~/.claude/settings.json` under `"hooks"`: run the command below with `busy` for
`UserPromptSubmit`, `PreToolUse` and `PostToolUse` (matcher `*`), and with `done` for `Stop` and
`SessionEnd`:

```json
{ "type": "command", "timeout": 5,
  "command": "sh \"$HOME/Library/Application Support/WorkPulse/agent-hook.sh\" claude-code busy 2>/dev/null || true" }
```

Codex, in `~/.codex/config.toml`: the same for `UserPromptSubmit`, `PreToolUse`, `PostToolUse`
(`busy`) and `Stop` (`done`), then approve the new hooks once in Codex:

```toml
[[hooks.Stop]]

[[hooks.Stop.hooks]]
type = "command"
command = "sh \"$HOME/Library/Application Support/WorkPulse/agent-hook.sh\" codex done 2>/dev/null || true"
timeout = 5
```

Turn the feature off in Settings › AI agents, or remove the hook entries.
