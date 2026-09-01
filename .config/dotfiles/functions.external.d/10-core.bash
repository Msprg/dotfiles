#!/usr/bin/env bash
# Frequently used filesystem and shell convenience helpers.

# Create a new directory and enter it
function mkd() {
	mkdir -p "$@" && cd "$_" || return
}

# Determine size of a file or total size of a directory
function fs() {
	local arg

	if du -b /dev/null > /dev/null 2>&1; then
		arg='-scbhk'
	else
		arg='-schk'
	fi

	if [ "$#" -gt 0 ]; then
		du "$arg" -- "$@"
	else
		du "$arg" .[^.]* ./*
	fi
}

# Print non-loopback interface addresses as: iface IPv4... IPv6...
function ips() {
	if ! command -v ip > /dev/null 2>&1; then
		echo "ips: 'ip' command not found" >&2
		return 1
	fi

	ip -o addr show | awk '
		$2 == "lo" { next }
		$3 == "inet" {
			ipv4[$2] = ipv4[$2] (ipv4[$2] ? " " : "") $4
			if (!seen[$2]++) order[++count] = $2
			next
		}
		$3 == "inet6" {
			ipv6[$2] = ipv6[$2] (ipv6[$2] ? " " : "") $4
			if (!seen[$2]++) order[++count] = $2
		}
		END {
			for (i = 1; i <= count; i++) {
				iface = order[i]
				if (!ipv4[iface] && !ipv6[iface]) {
					continue
				}

				line = iface
				if (ipv4[iface]) line = line " " ipv4[iface]
				if (ipv6[iface]) line = line " " ipv6[iface]
				print line
			}
		}
	'
}

function catt() {
	local item

	for item in "$@"; do
		if [[ -d "$item" ]]; then
			ls "$item"
		else
			cat "$item"
		fi
	done
}

ports() { if [[ -z "$*" ]]; then sudo netstat -pna; else sudo netstat -pna | grep -i "$@"; fi; }

# Seam for tests and future policy: every privileged access of the shared
# audit store goes through this single wrapper.
function __dotfiles_audit_sudo {
	sudo "$@"
}

function audit_bash_history {
	local audit_file legacy_file suffix='' show_all='false'

	while [ "$#" -gt 0 ]; do
		case "$1" in
			-a | --agent) suffix='.agent'; shift ;;
			-A | --all) show_all='true'; shift ;;
			*) break ;;
		esac
	done

	if [ "$show_all" = 'true' ]; then
		local all_dir="${DOTFILES_AUDIT_DIR:-/var/log/dotfiles/audit}"
		if [ ! -d "$all_dir" ]; then
			echo "No shared audit directory at $all_dir (user-scope install?). Try audit_bash_history without --all." >&2
			return 1
		fi
		if ! __dotfiles_audit_sudo -n true 2> /dev/null && ! __dotfiles_audit_sudo -v; then
			echo "audit_bash_history --all needs sudo access to $all_dir" >&2
			return 1
		fi
		if [ "$#" -eq 1 ] && [ "$1" = "-f" ]; then
			# Follows every log in the store (agent logs included).
			__dotfiles_audit_sudo sh -c 'set -- "$1"/*.log; exec tail -F "$@"' _ "$all_dir"
			return
		fi
		local merged
		if [ -n "$suffix" ]; then
			merged="$(__dotfiles_audit_sudo sh -c 'find "$1" -maxdepth 1 -name "*.agent.log" -exec cat {} +' _ "$all_dir" | sort -s -k1,1)"
		else
			merged="$(__dotfiles_audit_sudo sh -c 'find "$1" -maxdepth 1 -name "*.log" ! -name "*.agent.log" -exec cat {} +' _ "$all_dir" | sort -s -k1,1)"
		fi
		if [ -z "$merged" ]; then
			echo "No audit records found in $all_dir"
			return 0
		fi
		if [ "$#" -eq 0 ]; then
			printf '%s\n' "$merged" | nl -ba
			return
		fi
		if [ "$#" -eq 1 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
			printf '%s\n' "$merged" | tail -n "$1" | nl -ba
			return
		fi
		echo "Usage: audit_bash_history [-a|--agent] [-A|--all] [N|-f]"
		return 1
	fi

	if [ -n "$suffix" ]; then
		audit_file="$(agent_audit_history_file_path)"
		legacy_file="$HOME/.bash_history_audit_agent"
	else
		audit_file="$(audit_history_file_path)"
		legacy_file="$HOME/.bash_history_audit"
	fi
	if [ ! -s "$audit_file" ] && [ "$audit_file" != "$legacy_file" ] && [ -s "$legacy_file" ]; then
		echo "(no records at $audit_file; showing legacy $legacy_file)" >&2
		audit_file="$legacy_file"
	fi
	if [ ! -s "$audit_file" ]; then
		echo "No audit history found at $audit_file"
		return 0
	fi

	if [ "$#" -eq 0 ]; then
		nl -ba "$audit_file"
		return
	fi

	if [ "$#" -eq 1 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
		tail -n "$1" "$audit_file" | nl -ba
		return
	fi

	if [ "$#" -eq 1 ] && [ "$1" = "-f" ]; then
		tail -f "$audit_file"
		return
	fi

	echo "Usage: audit_bash_history [-a|--agent] [-A|--all] [N|-f]"
	return 1
}
