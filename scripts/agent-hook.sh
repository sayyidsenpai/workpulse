#!/bin/sh
# WorkPulse agent hook: tells WorkPulse that an AI coding agent is working.
#
# Called from Claude Code or Codex hooks (the hook's JSON arrives on stdin):
#   agent-hook.sh <tool> busy    on UserPromptSubmit, PreToolUse, PostToolUse
#   agent-hook.sh <tool> done    on Stop, SessionEnd
# <tool> is claude-code or codex.
#
# It only touches or removes an empty marker file named after the tool and the session id,
# and touches `.seen-<tool>` so WorkPulse can show that this agent is connected.
# It uses nothing else from the hook input, prints nothing (hook output could end up in the
# agent's context) and always succeeds, so it can never block or alter the agent.
# By project convention: no `set -e`, no `exit`.

dir="${WORKPULSE_DATA_DIR:-$HOME/Library/Application Support/WorkPulse}/agents"
id="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null | head -n 1 | tr -cd 'A-Za-z0-9_-')"
tool="$(printf '%s' "${1:-agent}" | tr -cd 'A-Za-z0-9_-')"
file="$dir/$tool.${id:-session}"

mkdir -p "$dir" 2>/dev/null && touch "$dir/.seen-$tool" 2>/dev/null
if [ "$2" = "busy" ]; then
    touch "$file" 2>/dev/null
else
    rm -f "$file" 2>/dev/null
fi
true
