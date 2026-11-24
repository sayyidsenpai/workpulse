#!/bin/sh
# WorkPulse agent hook: tells WorkPulse that an AI coding agent is working.
#
# Called from Claude Code or Codex hooks (the hook's JSON arrives on stdin):
#   agent-hook.sh <tool> busy    on UserPromptSubmit, PreToolUse, PostToolUse
#   agent-hook.sh <tool> done    on Stop, SessionEnd
# <tool> is claude-code or codex.
#
# It only writes or removes a marker file named after the tool and the session id, and touches
# `.seen-<tool>` so WorkPulse can show that this agent is connected. The marker holds the
# session's working folder (`cwd`), so WorkPulse can count only the folders the user chose.
# It uses nothing else from the hook input, prints nothing (hook output could end up in the
# agent's context) and always succeeds, so it can never block or alter the agent.
# By project convention: no `set -e`, no `exit`.

dir="${WORKPULSE_DATA_DIR:-$HOME/Library/Application Support/WorkPulse}/agents"
input="$(cat 2>/dev/null)"
id="$(printf '%s\n' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null | head -n 1 | tr -cd 'A-Za-z0-9_-')"
# The first "cwd" is the session's own: the common fields come before the tool input.
cwd="$(printf '%s\n' "$input" | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n 1 | sed 's/^"cwd"[[:space:]]*:[[:space:]]*"//; s/"$//')"
tool="$(printf '%s' "${1:-agent}" | tr -cd 'A-Za-z0-9_-')"
file="$dir/$tool.${id:-session}"

mkdir -p "$dir" 2>/dev/null && touch "$dir/.seen-$tool" 2>/dev/null
if [ "$2" = "busy" ]; then
    printf '%s' "$cwd" > "$file" 2>/dev/null
else
    rm -f "$file" 2>/dev/null
fi
true
