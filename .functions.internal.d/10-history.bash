#!/usr/bin/env bash
# Runtime history helpers and directory-change detection.

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

function audit_history_file_path {
	local base_histfile="${HISTFILE:-$HOME/.bash_history}"
	local audit_dir

	audit_dir="$(dirname "$base_histfile")"
	printf '%s/.bash_history_audit\n' "$audit_dir"
}

function ensure_audit_history_file {
	local audit_file
	local audit_dir

	audit_file="$(audit_history_file_path)"
	audit_dir="$(dirname "$audit_file")"

	mkdir -p "$audit_dir" || return 1
	if [ ! -e "$audit_file" ]; then
		touch "$audit_file" || return 1
		chmod 600 "$audit_file" || return 1
	fi
}

function last_history_command_for_audit {
	local command_raw
	local command_escaped

	# `fc -ln -1` prefixes entries with one leading whitespace character.
	command_raw="$(builtin fc -ln -1 | sed 's/^[[:space:]]//')"
	[ -z "$command_raw" ] && return 1

	# Keep single-line commands human-readable; only escape multiline entries
	# to keep the TSV audit log one-record-per-line.
	if [[ "$command_raw" == *$'\n'* ]]; then
		printf -v command_escaped '%q' "$command_raw"
		printf '%s\n' "$command_escaped"
		return
	fi

	printf '%s\n' "$command_raw"
}

function append_bash_history_audit {
	local current_histcmd="${HISTCMD:-}"
	local audit_file timestamp history_user history_user_display command_for_audit
	local cmd_exit duration_us duration_display

	[ -z "$current_histcmd" ] && return 0
	if [ "$current_histcmd" = "${__dotfiles_last_audit_histcmd:-}" ]; then
		return 0
	fi

	command_for_audit="$(last_history_command_for_audit)" || return 0
	ensure_audit_history_file || return 0
	audit_file="$(audit_history_file_path)"

	timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
	history_user="${BASH_HISTORY_USERNAME:-${USER:-unknown}}"
	history_user_display="$history_user"
	if [ "${#history_user_display}" -gt 24 ]; then
		history_user_display="${history_user_display:0:21}..."
	fi
	cmd_exit="${last_cmd_exit_code:-0}"
	duration_us="${_last_cmd_us:-0}"
	duration_display="$(format_duration_us "$duration_us")"

	if printf '%-24s  %-24s  exit:%-3s  took:%-9s  %s\n' \
		"$timestamp" "$history_user_display" "$cmd_exit" "$duration_display" "$command_for_audit" >> "$audit_file"; then
		__dotfiles_last_audit_histcmd="$current_histcmd"
	fi
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
