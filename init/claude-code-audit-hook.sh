#!/usr/bin/env bash
# Claude Code PostToolUse hook: append every Bash tool call to the agent audit
# log used by ~/.dotfiles_agent_audit (default ~/.bash_history_audit_agent).
#
# Claude Code executes tool commands in `bash -c` shells that read no rc file,
# so the dotfiles cannot observe them; this hook receives the command, exit
# code and cwd from Claude Code itself. Same record format as the shell-side
# recorder (duration is not available to hooks and is written as "-").
#
# Install (user scope, applies to every project) in ~/.claude/settings.json:
#
#   {
#     "hooks": {
#       "PostToolUse": [
#         {
#           "matcher": "Bash",
#           "hooks": [
#             { "type": "command", "command": "$HOME/dotFiles/init/claude-code-audit-hook.sh" }
#           ]
#         }
#       ]
#     }
#   }
#
# Adjust the path if the repo lives elsewhere (see ~/.dotfiles_repo_dir).
# Requires python3 or jq. Never fails the tool call: exits 0 on any error.

set -u

audit_file="${DOTFILES_AGENT_AUDIT_FILE:-$HOME/.bash_history_audit_agent}"
max_chars="${DOTFILES_AGENT_AUDIT_MAX_CHARS:-4000}"
[[ "$max_chars" =~ ^[0-9]+$ ]] || max_chars=4000

payload="$(cat 2> /dev/null)" || exit 0
[ -n "$payload" ] || exit 0

# Extract command / exit code / cwd separated by ASCII unit separator (0x1f);
# the command itself may contain newlines and tabs.
sep=$'\x1f'
if command -v python3 > /dev/null 2>&1; then
	parsed="$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get("tool_name") != "Bash":
    sys.exit(0)
cmd = (d.get("tool_input") or {}).get("command") or ""
resp = d.get("tool_response")
code = d.get("exit_code")
if code is None and isinstance(resp, dict):
    code = resp.get("exit_code", resp.get("exitCode"))
    if code is None and resp.get("interrupted"):
        code = "int"
if code is None:
    code = "-"
sys.stdout.write("\x1f".join([cmd, str(code), d.get("cwd") or ""]))
')" || exit 0
elif command -v jq > /dev/null 2>&1; then
	parsed="$(printf '%s' "$payload" | jq -r '
		select(.tool_name == "Bash") |
		[ (.tool_input.command // ""),
		  ((.exit_code // .tool_response.exit_code // .tool_response.exitCode // "-") | tostring),
		  (.cwd // "") ] | join("\u001f")' 2> /dev/null)" || exit 0
else
	exit 0
fi
[ -n "$parsed" ] || exit 0

command_raw="${parsed%%"$sep"*}"
rest="${parsed#*"$sep"}"
cmd_exit="${rest%%"$sep"*}"
[ -n "${command_raw:-}" ] || exit 0

if (( max_chars > 0 && ${#command_raw} > max_chars )); then
	command_raw="${command_raw:0:max_chars} ...[truncated $(( ${#command_raw} - max_chars )) chars]"
fi
if [[ "$command_raw" == *$'\n'* ]]; then
	printf -v command_for_audit '%q' "$command_raw"
else
	command_for_audit="$command_raw"
fi

audit_dir="${audit_file%/*}"
[ "$audit_dir" = "$audit_file" ] && audit_dir='.'
mkdir -p "$audit_dir" 2> /dev/null || exit 0
if [ ! -e "$audit_file" ]; then
	{ : > "$audit_file" && chmod 600 "$audit_file"; } 2> /dev/null || exit 0
fi

timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
history_user="${BASH_HISTORY_USERNAME:-${USER:-unknown}}"
[ "${#history_user}" -gt 24 ] && history_user="${history_user:0:21}..."

printf '%-24s  %-24s  %-14s  exit:%-3s  took:%-9s  %s\n' \
	"$timestamp" "$history_user" 'claude-code' "${cmd_exit:--}" '-' "$command_for_audit" >> "$audit_file" 2> /dev/null
exit 0
