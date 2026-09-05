#!/usr/bin/env bash
# Runtime history helpers, directory-change detection, and the command audit.

#!SECTION per-directory Bash history
function check_for_local_history {
	function main {
		if found_local_history_file; then
			if [ ! "$PWD" == "$HOME" ]; then
				echo "⌚ Using local Bash history"
			fi

			use_history_file "$PWD/.bash_history"
		else
			use_history_file ~/.bash_history
		fi
	}

	function found_local_history_file {
		[ -e .bash_history ]
	}

	function use_history_file {
		history -w
		history -c
		export HISTFILE="$1"
		history -r
	}

	main
}

#!SECTION audit file resolution
# The audit log is deliberately decoupled from HISTFILE: per-directory local
# history (DOTFILES_FEATURE_LOCAL_HISTORY) affects only where *history* is
# kept, never where the audit trail goes.
#
# Resolution order (see __dotfiles_audit_resolve_file):
#   1. explicit override (DOTFILES_AUDIT_FILE / DOTFILES_AGENT_AUDIT_FILE)
#   2. shared store: $DOTFILES_AUDIT_DIR (default /var/log/dotfiles/audit for
#      system-scope installs) / <identity>[.agent].log — the directory is
#      root-owned mode 1733, files are 0600 per user
#   3. account-named file in the shared store (identity's file unwritable,
#      e.g. `su` kept another user's BASH_HISTORY_USERNAME in the env)
#   4. legacy per-user file in $HOME

function __dotfiles_audit_sanitize_identity {
	# BASH_HISTORY_USERNAME is remote-controlled text that ends up in a
	# filename: allow a conservative charset, no leading dot/dash, max 64.
	local identity="$1"
	[[ "$identity" =~ ^[A-Za-z0-9_@][A-Za-z0-9._@-]{0,63}$ ]]
}

# The login-session map lets the SSH-key identity (BASH_HISTORY_USERNAME) follow
# a user across privilege escalation. env_keep carries it through the sudo
# family, but `su -` / `sudo su -` scrub the environment for the login shell.
# The kernel audit session id (/proc/self/sessionid) is set by PAM at login,
# is immutable, and is inherited by every descendant INCLUDING an env-scrubbing
# `su -`. So the login shell records "<sessionid> -> identity" once, and any
# escalated shell that lost the env var recovers it by its own (identical)
# session id. The map lives on tmpfs (/run) so stale sessionids never survive a
# reboot (they are reused with low numbers each boot).
function __dotfiles_audit_session_id {
	local sid=''
	if [ -n "${DOTFILES_AUDIT_SESSION_ID:-}" ]; then
		sid="$DOTFILES_AUDIT_SESSION_ID"
	elif [ -r /proc/self/sessionid ]; then
		IFS= read -r sid < /proc/self/sessionid 2> /dev/null
	fi
	# 4294967295 (uint32 -1) is the kernel's "no audit session" sentinel.
	case "$sid" in
		'' | *[!0-9]* | 4294967295) return 1 ;;
	esac
	printf '%s\n' "$sid"
}

function __dotfiles_audit_session_dir {
	printf '%s\n' "${DOTFILES_AUDIT_SESSION_DIR:-/run/dotfiles-audit/sessions}"
}

# The kernel login uid (/proc/self/loginuid): the uid that opened this login
# session, set once by PAM and inherited unchanged across su/sudo (like the
# session id). It is the uid that owns the legitimate seed file for this
# session, so recovery uses it to reject a seed planted by any other user.
function __dotfiles_audit_loginuid {
	local uid=''
	[ -r /proc/self/loginuid ] || return 1
	IFS= read -r uid < /proc/self/loginuid 2> /dev/null
	case "$uid" in '' | *[!0-9]* | 4294967295) return 1 ;; esac
	printf '%s\n' "$uid"
}

function __dotfiles_audit_file_owner_uid {
	local uid
	uid="$(stat -c %u "$1" 2> /dev/null || stat -f %u "$1" 2> /dev/null)" || return 1
	case "$uid" in '' | *[!0-9]*) return 1 ;; esac
	printf '%s\n' "$uid"
}

function __dotfiles_audit_seed_session {
	local identity="$1" create_only="${2:-false}" sid dir file existing
	sid="$(__dotfiles_audit_session_id)" || return 0
	dir="$(__dotfiles_audit_session_dir)"
	[ -d "$dir" ] && [ -w "$dir" ] || return 0
	file="$dir/$sid"
	if [ -r "$file" ]; then
		IFS= read -r existing < "$file" 2> /dev/null
		[ "$existing" = "$identity" ] && return 0
	fi
	# create_only: an account-name seed must never overwrite a key identity
	# (or another user's unreadable entry) already recorded for the session.
	[ "$create_only" = 'true' ] && [ -e "$file" ] && return 0
	# Own file, 0600: peers cannot read another session's identity; root (an
	# escalated shell) reads it regardless.
	( umask 077; printf '%s\n' "$identity" > "$file" ) 2> /dev/null || true
	dotfiles_dbg ".FUNCTIONS audit session seeded: sid=$sid identity='$identity' file='$file'" >&2
	return 0
}

function __dotfiles_audit_recover_session {
	local sid dir file identity owner_uid login_uid
	sid="$(__dotfiles_audit_session_id)" || return 1
	dir="$(__dotfiles_audit_session_dir)"
	file="$dir/$sid"
	[ -r "$file" ] || return 1
	# Trust the seed only if it is owned by the uid that owns THIS login session
	# (the kernel loginuid). The map dir is 1733 — world-writable — so any local
	# user can pre-create a session file for an id they do not own; the sticky
	# bit then stops the real login shell from overwriting it. Without this
	# check an escalated (even root) shell would adopt that planted identity,
	# letting an unrelated local account forge who a privileged shell is audited
	# as. A legitimate seed is written by the session's own login shell and is
	# therefore owned by the loginuid; a planted one is not. If either value is
	# unavailable (no audit login uid), refuse to recover rather than trust an
	# unverifiable file.
	login_uid="$(__dotfiles_audit_loginuid)" || return 1
	owner_uid="$(__dotfiles_audit_file_owner_uid "$file")" || return 1
	if [ "$owner_uid" != "$login_uid" ]; then
		dotfiles_dbg ".FUNCTIONS audit session recover rejected: '$file' owned by uid $owner_uid != loginuid $login_uid (possible planted identity)" >&2
		return 1
	fi
	IFS= read -r identity < "$file" 2> /dev/null
	[ -n "$identity" ] && __dotfiles_audit_sanitize_identity "$identity" || return 1
	printf '%s\n' "$identity"
}

function __dotfiles_audit_identity {
	local identity="${BASH_HISTORY_USERNAME:-}"
	local recovered

	if [ -n "$identity" ] && __dotfiles_audit_sanitize_identity "$identity"; then
		# We are (or descend from) the shell where the SSH key set the
		# identity: record it so escalated shells in this session recover it.
		__dotfiles_audit_seed_session "$identity"
		printf '%s\n' "$identity"
		return 0
	fi
	if [ -n "$identity" ]; then
		dotfiles_dbg ".FUNCTIONS audit identity rejected: BASH_HISTORY_USERNAME failed sanitization; trying session map" >&2
	fi
	# No usable env identity (e.g. after `su -` scrubbed it): recover the
	# login-session identity if this session was seeded.
	if recovered="$(__dotfiles_audit_recover_session)"; then
		dotfiles_dbg ".FUNCTIONS audit identity recovered from session map: '$recovered'" >&2
		printf '%s\n' "$recovered"
		return 0
	fi
	# No key identity anywhere in this login session (password login, console,
	# ...): the account IS the identity. Seed it as well, so `sudo su` / `su -`
	# shells of this session record who logged in rather than "root".
	identity="$(id -un)"
	__dotfiles_audit_seed_session "$identity" 'true'
	printf '%s\n' "$identity"
}

# A shared-store file is usable by this shell only when the shell OWNS it
# (bash -O: owner is the effective uid). `-w` is not enough: root passes -w
# on anyone's file, yet fs.protected_regular (on by default on Debian, Ubuntu,
# RHEL, ...) makes the kernel refuse an O_CREAT open -- every `>>` -- of a
# file owned by another user inside a world-writable sticky directory such as
# the 1733 store, and that refusal has no capability bypass: it hits root too.
function __dotfiles_audit_shared_file_usable {
	local file="$1" dir="$2"
	if [ -e "$file" ]; then
		[ -w "$file" ] && { [ ! -k "$dir" ] || [ -O "$file" ]; }
	else
		[ -w "$dir" ]
	fi
}

function __dotfiles_audit_resolve_file {
	local override="$1" suffix="$2" legacy="$3"
	local dir candidate account_candidate identity account

	if [ -n "$override" ]; then
		printf '%s\n' "$override"
		return 0
	fi

	dir="${DOTFILES_AUDIT_DIR:-}"
	if [ -z "$dir" ] && [ "${DOTFILES_INSTALL_SCOPE:-user}" = 'system' ]; then
		dir='/var/log/dotfiles/audit'
	fi

	if [ -n "$dir" ] && [ -d "$dir" ] && [ -x "$dir" ]; then
		identity="$(__dotfiles_audit_identity)"
		account="$(id -un)"
		candidate="$dir/${identity}${suffix}.log"
		account_candidate="$dir/${account}${suffix}.log"
		# An identity naming ANOTHER local account (sudo su from that account,
		# or a key comment equal to a username) never claims that account's
		# file: in the sticky store a file is appendable by its owner only, so
		# taking it would either fail right here (root after sudo su) or lock
		# the account's own shells out of it for good. Record under this
		# account's file instead; the identity still fills the user column.
		if [ "$identity" != "$account" ] && id -u "$identity" > /dev/null 2>&1; then
			dotfiles_dbg ".FUNCTIONS audit resolve: identity '$identity' is a local account; recording under '$account_candidate'" >&2
			candidate="$account_candidate"
		fi
		# Repair: an older runtime handed root's own file over to SUDO_USER,
		# after which no root shell could append to it. Root's account file
		# only, root only.
		if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -e "$account_candidate" ] && [ ! -O "$account_candidate" ]; then
			chown root "$account_candidate" 2> /dev/null \
				&& dotfiles_dbg ".FUNCTIONS audit resolve: reclaimed '$account_candidate' for root" >&2
		fi
		if __dotfiles_audit_shared_file_usable "$candidate" "$dir"; then
			printf '%s\n' "$candidate"
			return 0
		fi
		# The identity's file exists but belongs to someone else (0600): fall
		# back to a file named after the account; the identity still appears
		# in the user column of every record.
		if [ "$account_candidate" != "$candidate" ] \
			&& __dotfiles_audit_shared_file_usable "$account_candidate" "$dir"; then
			dotfiles_dbg ".FUNCTIONS audit resolve: '$candidate' not writable; using '$account_candidate'" >&2
			printf '%s\n' "$account_candidate"
			return 0
		fi
		dotfiles_dbg ".FUNCTIONS audit resolve: shared dir '$dir' unusable for identity '$identity'; using legacy '$legacy'" >&2
	fi

	printf '%s\n' "$legacy"
}

function audit_history_file_path {
	if [ -z "${__dotfiles_audit_file_cached:-}" ]; then
		__dotfiles_audit_file_cached="$(__dotfiles_audit_resolve_file \
			"${DOTFILES_AUDIT_FILE:-}" '' "$HOME/.bash_history_audit")"
	fi
	printf '%s\n' "$__dotfiles_audit_file_cached"
}

function agent_audit_history_file_path {
	if [ -z "${__dotfiles_agent_audit_file_cached:-}" ]; then
		__dotfiles_agent_audit_file_cached="$(__dotfiles_audit_resolve_file \
			"${DOTFILES_AGENT_AUDIT_FILE:-}" '.agent' "$HOME/.bash_history_audit_agent")"
	fi
	printf '%s\n' "$__dotfiles_agent_audit_file_cached"
}

function __dotfiles_ensure_audit_file_at {
	local audit_file="$1"
	local audit_dir
	local mkdir_rc touch_rc chmod_rc

	audit_dir="$(dirname "$audit_file")"
	dotfiles_dbg ".FUNCTIONS audit ensure file: audit_file='$audit_file' audit_dir='$audit_dir'"

	if [ ! -d "$audit_dir" ]; then
		mkdir -p "$audit_dir"
		mkdir_rc=$?
		if [ "$mkdir_rc" -ne 0 ]; then
			dotfiles_dbg ".FUNCTIONS audit ensure file failed: mkdir -p '$audit_dir' rc=$mkdir_rc"
			return 1
		fi
	fi
	if [ ! -e "$audit_file" ]; then
		dotfiles_dbg ".FUNCTIONS audit ensure file creating '$audit_file'"
		touch "$audit_file"
		touch_rc=$?
		if [ "$touch_rc" -ne 0 ]; then
			dotfiles_dbg ".FUNCTIONS audit ensure file failed: touch '$audit_file' rc=$touch_rc"
			return 1
		fi
		chmod 600 "$audit_file"
		chmod_rc=$?
		if [ "$chmod_rc" -ne 0 ]; then
			dotfiles_dbg ".FUNCTIONS audit ensure file failed: chmod 600 '$audit_file' rc=$chmod_rc"
			return 1
		fi
		# The creator keeps the file: in the sticky store only the owner can
		# append (protected_regular), so handing a fresh file to the identity
		# or to SUDO_USER -- as an older runtime did -- locked THIS shell out
		# of its own log. The resolver already routes an identity that names
		# another local account to this account's file, so nothing here ever
		# creates a file some other account will need.
		dotfiles_dbg ".FUNCTIONS audit ensure file created '$audit_file' with mode 600"
	elif ! __dotfiles_audit_shared_file_usable "$audit_file" "$audit_dir"; then
		dotfiles_dbg ".FUNCTIONS audit ensure file warning: '$audit_file' exists but this shell cannot append to it (owner/mode)"
		return 1
	fi

	dotfiles_dbg ".FUNCTIONS audit ensure file ready: '$audit_file'"
	return 0
}

function ensure_audit_history_file {
	if __dotfiles_ensure_audit_file_at "$(audit_history_file_path)"; then
		return 0
	fi
	# One retry after re-resolving: covers the shared dir appearing or
	# disappearing after this shell started, and permission/SELinux denials
	# (the resolver then falls back to the legacy $HOME file).
	dotfiles_dbg ".FUNCTIONS audit ensure file retrying after re-resolve"
	unset __dotfiles_audit_file_cached
	# Refill the cache in THIS shell (a $(...) call would fill it only in a
	# throwaway subshell and leave every later call re-resolving).
	audit_history_file_path > /dev/null
	__dotfiles_ensure_audit_file_at "$(audit_history_file_path)"
}

#!SECTION audit record helpers
function last_history_command_for_audit {
	local command_raw
	local command_escaped

	# `fc -ln -1` prefixes entries with leading whitespace (a tab
	# interactively, sometimes more); strip it all so the recorded command
	# compares cleanly against $BASH_COMMAND and prior audit lines.
	command_raw="$(builtin fc -ln -1 | sed 's/^[[:space:]]*//')"
	if [ -z "$command_raw" ]; then
		dotfiles_dbg ".FUNCTIONS audit command read skipped: empty command from fc -ln -1" >&2
		return 1
	fi

	# Keep single-line commands human-readable; only escape multiline entries
	# to keep the audit log one-record-per-line.
	if [[ "$command_raw" == *$'\n'* ]]; then
		printf -v command_escaped '%q' "$command_raw"
		dotfiles_dbg ".FUNCTIONS audit command read multiline: raw_len=${#command_raw} escaped_len=${#command_escaped}" >&2
		printf '%s\n' "$command_escaped"
		return
	fi

	dotfiles_dbg ".FUNCTIONS audit command read single-line: len=${#command_raw}" >&2
	printf '%s\n' "$command_raw"
}

function last_history_event_id_for_audit {
	local history_line

	history_line="$(builtin history 1)"
	if [[ "$history_line" =~ ^[[:space:]]*([0-9]+)[[:space:]] ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi

	dotfiles_dbg ".FUNCTIONS audit event read skipped: could not parse history event from history 1" >&2
	return 1
}

function parse_audit_line_for_dedupe {
	local audit_line="$1"

	# Expected format:
	# <timestamp>  <user>  exit:<code>  took:<duration>  <command>
	if [[ "$audit_line" =~ ^([^[:space:]]+)[[:space:]]{2,}([^[:space:]]+)[[:space:]]{2,}exit:[[:space:]]*([-0-9]+)[[:space:]]{2,}took:[^[:space:]]+[[:space:]]{2,}(.*)$ ]]; then
		printf '%s\t%s\t%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
		return 0
	fi

	return 1
}

function replace_last_line_in_file {
	local target_file="$1"
	local replacement_line="$2"
	local target_dir temp_file

	target_dir="$(dirname "$target_file")"
	temp_file="$(mktemp "$target_dir/.bash_history_audit.tmp.XXXXXX")" || return 1

	if [ -s "$target_file" ]; then
		sed '$d' "$target_file" > "$temp_file" || {
			rm -f "$temp_file"
			return 1
		}
	fi

	printf '%s\n' "$replacement_line" >> "$temp_file" || {
		rm -f "$temp_file"
		return 1
	}

	# Truncate-write in place instead of mv: preserves the file's owner (a
	# sudo-root shell would otherwise flip it to root and break the user's
	# later appends), its SELinux context, and its inode (tail -f viewers).
	# Safe because every writer serializes on the flock in the caller.
	cat "$temp_file" > "$target_file" 2> /dev/null || {
		rm -f "$temp_file"
		return 1
	}
	rm -f "$temp_file"
}

#!SECTION audit append
function append_bash_history_audit {
	local audit_file timestamp history_user history_user_display command_for_audit
	local cmd_exit duration_us duration_display
	local command_read_rc ensure_rc write_rc
	local history_event history_key current_histfile
	local audit_file_writable='false'
	local audit_dir_writable='false'
	local audit_line lock_file lock_fd lock_rc
	local last_audit_line last_audit_user last_audit_exit last_audit_command parsed_last_line
	local should_replace='false'
	local capture_seen="${__dotfiles_audit_capture_seen:-0}"
	local captured_cmd="${__dotfiles_audit_captured_cmd:-}"

	# Skip the pre-first-command prompt of an interactive shell. The very first
	# PROMPT_COMMAND cycle runs before the user has typed anything, so `history 1`
	# is the last command inherited from the previous session via HISTFILE, not a
	# command run here. Recording it fabricates a phantom entry (fresh timestamp,
	# exit:0) — or rewrites the previous record's timestamp — at every login.
	# HISTCMD does not advance past its start-of-shell value until the user
	# actually runs something, which distinguishes the inherited entry from a
	# freshly typed first command (and from a fresh shell with no history).
	# Non-interactive callers (the unit tests drive append directly) are exempt.
	if [[ $- == *i* ]]; then
		if [ -z "${__dotfiles_audit_start_histcmd:-}" ]; then
			__dotfiles_audit_start_histcmd="${HISTCMD:-0}"
		fi
		if [ "${HISTCMD:-0}" = "$__dotfiles_audit_start_histcmd" ]; then
			dotfiles_dbg ".FUNCTIONS audit append skipped: pre-first-command prompt (HISTCMD=${HISTCMD:-0} unchanged since shell start; inherited history not re-audited)"
			return 0
		fi
	fi

	history_event="$(last_history_event_id_for_audit)" || return 0
	current_histfile="${HISTFILE:-$HOME/.bash_history}"
	history_key="${current_histfile}:${history_event}"

	command_for_audit="$(last_history_command_for_audit)"
	command_read_rc=$?
	if [ "$command_read_rc" -ne 0 ]; then
		dotfiles_dbg ".FUNCTIONS audit append skipped: command read failed rc=$command_read_rc"
		return 0
	fi

	if [ "$history_key" = "${__dotfiles_last_audit_history_key:-}" ]; then
		# No new history entry. HISTCONTROL=ignoreboth suppresses two kinds of
		# commands: consecutive duplicates and space-prefixed ones. The DEBUG
		# capture tells them apart — a captured command identical to the last
		# history entry is a re-run of it (audit it with its fresh exit code);
		# anything else (space-prefixed opt-out, empty Enter) is skipped.
		if [ "$capture_seen" = 1 ] && [ "$captured_cmd" = "$command_for_audit" ]; then
			dotfiles_dbg ".FUNCTIONS audit append: duplicate re-run detected for history event '$history_key'"
			__dotfiles_audit_capture_seen=0
		else
			dotfiles_dbg ".FUNCTIONS audit append skipped: history event '$history_key' already audited"
			__dotfiles_audit_capture_seen=0
			return 0
		fi
	else
		__dotfiles_audit_capture_seen=0
	fi

	dotfiles_dbg ".FUNCTIONS audit append start: history_event='$history_event' history_key='$history_key' last_audited='${__dotfiles_last_audit_history_key:-}' HISTFILE='$current_histfile'"
	dotfiles_dbg ".FUNCTIONS audit append command ready: len=${#command_for_audit}"

	ensure_audit_history_file
	ensure_rc=$?
	if [ "$ensure_rc" -ne 0 ]; then
		dotfiles_dbg ".FUNCTIONS audit append skipped: ensure_audit_history_file failed rc=$ensure_rc"
		return 0
	fi
	audit_file="$(audit_history_file_path)"
	if [ -w "$audit_file" ]; then
		audit_file_writable='true'
	fi
	if [ -w "$(dirname "$audit_file")" ]; then
		audit_dir_writable='true'
	fi

	timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
	# Use the resolved identity so the record body matches the filename and so
	# an escalated shell (su -) recovers the login identity from the session
	# map instead of recording root/USER.
	history_user="$(__dotfiles_audit_identity)"
	# Strip control chars (esp. newlines): the identity may come from the
	# attacker-influenceable BASH_HISTORY_USERNAME and must not forge records.
	history_user="${history_user//[![:print:]]/}"
	history_user_display="$history_user"
	if [ "${#history_user_display}" -gt 24 ]; then
		history_user_display="${history_user_display:0:21}..."
	fi
	cmd_exit="${last_cmd_exit_code:-0}"
	if [[ "${DOTFILES_FEATURE_TRACK_COMMAND_DURATION:-false}" == "true" ]]; then
		duration_us="${_last_cmd_us:-0}"
		duration_display="$(format_duration_us "$duration_us")"
	else
		duration_us=0
		duration_display='-'
	fi
	dotfiles_dbg ".FUNCTIONS audit append write attempt: file='$audit_file' file_writable=$audit_file_writable dir_writable=$audit_dir_writable exit=$cmd_exit duration_us=$duration_us duration='$duration_display'"

	printf -v audit_line '%-24s  %-24s  exit:%-3s  took:%-9s  %s' \
		"$timestamp" "$history_user_display" "$cmd_exit" "$duration_display" "$command_for_audit"

	lock_file="${audit_file}.lock"
	lock_fd=''
	if command -v flock > /dev/null 2>&1; then
		# The group scopes 2>/dev/null to the open: a bare `exec ... 2>` would
		# redirect the shell's stderr for good.
		{ exec {lock_fd}>>"$lock_file"; } 2> /dev/null
		lock_rc=$?
		if [ "$lock_rc" -ne 0 ]; then
			dotfiles_dbg ".FUNCTIONS audit append lock open failed: lock='$lock_file' rc=$lock_rc"
			return 0
		fi
		flock -x "$lock_fd"
		lock_rc=$?
		if [ "$lock_rc" -ne 0 ]; then
			dotfiles_dbg ".FUNCTIONS audit append lock acquire failed: lock='$lock_file' rc=$lock_rc"
			exec {lock_fd}>&-
			return 0
		fi
	fi

	if [ -s "$audit_file" ]; then
		last_audit_line="$(tail -n 1 "$audit_file")"
		parsed_last_line="$(parse_audit_line_for_dedupe "$last_audit_line")"
		if [ $? -eq 0 ]; then
			IFS=$'\t' read -r last_audit_user last_audit_exit last_audit_command <<< "$parsed_last_line"
			if [ "$last_audit_user" = "$history_user_display" ] \
				&& [ "$last_audit_exit" = "$cmd_exit" ] \
				&& [ "$last_audit_command" = "$command_for_audit" ]; then
				should_replace='true'
			fi
		fi
	fi

	if [ "$should_replace" = 'true' ]; then
		replace_last_line_in_file "$audit_file" "$audit_line"
		write_rc=$?
		if [ "$write_rc" -eq 0 ]; then
			dotfiles_dbg ".FUNCTIONS audit append replaced last entry: user='$history_user_display' exit=$cmd_exit"
		fi
	else
		printf '%s\n' "$audit_line" >> "$audit_file" 2> /dev/null
		write_rc=$?
		if [ "$write_rc" -eq 0 ]; then
			dotfiles_dbg ".FUNCTIONS audit append appended new entry: user='$history_user_display' exit=$cmd_exit"
		fi
	fi

	if [ -n "$lock_fd" ]; then
		flock -u "$lock_fd" > /dev/null 2>&1 || true
		exec {lock_fd}>&-
	fi

	if [ "${write_rc:-1}" -eq 0 ]; then
		__dotfiles_last_audit_history_key="$history_key"
		dotfiles_dbg ".FUNCTIONS audit append success: history_event='$history_event' recorded in '$audit_file'"
	else
		dotfiles_dbg ".FUNCTIONS audit append failed: rc=${write_rc:-1} file='$audit_file' file_writable=$audit_file_writable dir_writable=$audit_dir_writable"
		# Never print at the prompt; re-resolve next time instead (the file
		# may have changed owner or mode, the store may have come or gone).
		unset __dotfiles_audit_file_cached
	fi
}

#!SECTION DEBUG-trap capture (closes the HISTCONTROL=ignoreboth audit hole)
# Bash has a single DEBUG trap slot, so this handler serves both consumers:
# the audit's first-command capture and the duration timer's start stamp
# (DOTFILES_FEATURE_TRACK_COMMAND_DURATION_METHOD=debug). Without functrace
# the trap fires only for top-level commands, exactly what both need.
# If a foreign tool later replaces the trap, capture_seen simply stays 0 and
# the audit falls back to history-advance-only behavior — nothing breaks.
function __dotfiles_debug_trap_hook {
	case "$BASH_COMMAND" in
		# Our own PROMPT_COMMAND parts: never capture them and never start the
		# timer on them. do_my_checks clears the timer; a start stamp taken on
		# the trailing capture-arm step would date the next command from the
		# moment the prompt was drawn and report idle time as its duration.
		# Clearing the boundary flag here means an externally-appended
		# PROMPT_COMMAND part that runs after ours is treated as prompt-internal
		# too; PS0 re-sets the flag right before the actual user command.
		__dotfiles_* | do_my_checks | capture_prompt_exit_status | timer_stop | append_bash_history_audit)
			__dotfiles_at_user_command=''
			;;
		*)
			# With the PS0 boundary active (full/light on bash >= 4.4), only the
			# user's command — which PS0 marks by setting the flag just before it
			# runs — arms the timer and consumes the capture; a stray
			# PROMPT_COMMAND part added by another tool (e.g. an appended
			# `history -a`) runs with the flag cleared and is ignored, so idle
			# prompt time is no longer counted as the next command's duration.
			# When the boundary is inactive (bash < 4.4, no PS0; or the timer is
			# off), fall back to arming on the first non-excluded command.
			if [ "${__dotfiles_prompt_boundary_active:-0}" = 1 ] && [ "${__dotfiles_at_user_command:-}" != 1 ]; then
				:
			else
				if [ "${__dotfiles_audit_capture_armed:-0}" = 1 ]; then
					__dotfiles_audit_capture_armed=0
					__dotfiles_audit_captured_cmd="$BASH_COMMAND"
					__dotfiles_audit_capture_seen=1
				fi
				if [ "${__dotfiles_debug_timer_armed:-0}" = 1 ]; then
					timer_start
				fi
			fi
			;;
	esac
	return 0
}

function __dotfiles_audit_capture_arm {
	# Appended as the LAST element of PROMPT_COMMAND so that commands other
	# tools add to PROMPT_COMMAND never count as the captured user command.
	__dotfiles_audit_capture_armed=1
	return 0
}

function __dotfiles_install_debug_trap {
	trap '__dotfiles_debug_trap_hook' DEBUG
}

# Lean prompt hook for profiles without full prompt hooks (minimal): captures
# the exit code and writes the audit record, nothing else.
function __dotfiles_audit_prompt_hook {
	last_cmd_exit_code=$?
	if [[ "${DOTFILES_FEATURE_HISTORY_AUDIT:-true}" == "true" ]]; then
		append_bash_history_audit
	fi
	return 0
}

function __dotfiles_install_audit_capture {
	# Used with full prompt hooks: do_my_checks writes the record; this only
	# adds the arm step + DEBUG trap for duplicate-re-run detection.
	case ";${PROMPT_COMMAND:-};" in
		*";__dotfiles_audit_capture_arm;"*) ;;
		*)
			if [ -n "${PROMPT_COMMAND:-}" ]; then
				PROMPT_COMMAND="${PROMPT_COMMAND};__dotfiles_audit_capture_arm"
			else
				PROMPT_COMMAND="__dotfiles_audit_capture_arm"
			fi
			;;
	esac
	__dotfiles_install_debug_trap
	dotfiles_dbg ".FUNCTIONS installed audit capture arm + DEBUG trap; PROMPT_COMMAND='${PROMPT_COMMAND:-}'"
}

function __dotfiles_install_lean_audit_hook {
	# Minimal-profile path: strip any of our parts from PROMPT_COMMAND, then
	# prepend the lean hook and append the capture arm.
	local current_prompt_command="${PROMPT_COMMAND:-}"
	local rebuilt_prompt_command=''
	local prompt_part
	local prompt_parts=()

	# Fold newlines to ; first: `read` stops at the first newline, which
	# would otherwise silently drop a multi-line PROMPT_COMMAND tail.
	current_prompt_command="${current_prompt_command//$'\n'/;}"
	IFS=';' read -r -a prompt_parts <<< "$current_prompt_command"
	for prompt_part in "${prompt_parts[@]}"; do
		prompt_part="${prompt_part#"${prompt_part%%[![:space:]]*}"}"
		prompt_part="${prompt_part%"${prompt_part##*[![:space:]]}"}"

		case "$prompt_part" in
			'' | do_my_checks | capture_prompt_exit_status | __dotfiles_audit_prompt_hook | __dotfiles_audit_capture_arm)
				continue
				;;
		esac

		if [ -z "$rebuilt_prompt_command" ]; then
			rebuilt_prompt_command="$prompt_part"
		else
			rebuilt_prompt_command="${rebuilt_prompt_command};${prompt_part}"
		fi
	done

	if [ -n "$rebuilt_prompt_command" ]; then
		PROMPT_COMMAND="__dotfiles_audit_prompt_hook;${rebuilt_prompt_command};__dotfiles_audit_capture_arm"
	else
		PROMPT_COMMAND="__dotfiles_audit_prompt_hook;__dotfiles_audit_capture_arm"
	fi
	__dotfiles_install_debug_trap
	dotfiles_dbg ".FUNCTIONS installed lean audit hook; PROMPT_COMMAND='$PROMPT_COMMAND'"
}

function changing_directory {
	# Compare current directory with the previously seen one.
	# This avoids history parsing and alias scans on every prompt while still
	# catching `cd`, aliases, `pushd/popd`, and any other PWD-changing command.
	if [[ "$PWD" != "${__dotfiles_last_pwd:-$PWD}" ]]; then
		__dotfiles_last_pwd="$PWD"
		return 0
	fi
	return 1
}

#!SECTION module state
__dotfiles_last_audit_history_key=''
# Set on the first interactive append; commands are only audited once HISTCMD
# has advanced past it (see append_bash_history_audit's pre-first-command skip).
__dotfiles_audit_start_histcmd=''
__dotfiles_audit_capture_armed=0
__dotfiles_audit_capture_seen=0
__dotfiles_audit_captured_cmd=''
# PS0 prompt boundary (see __dotfiles_debug_trap_hook and the timer install in
# 40-prompt.bash). boundary_active is turned on only when a PS0 marker can mark
# the user-command boundary; at_user_command is set to 1 by that PS0 marker and
# cleared by our PROMPT_COMMAND parts.
__dotfiles_prompt_boundary_active=0
__dotfiles_at_user_command=''
# Resolve the audit paths once at load time (in the parent shell, so the
# cache actually persists); ensure_audit_history_file re-resolves on failure.
__dotfiles_audit_file_cached=''
__dotfiles_agent_audit_file_cached=''
audit_history_file_path > /dev/null
agent_audit_history_file_path > /dev/null
