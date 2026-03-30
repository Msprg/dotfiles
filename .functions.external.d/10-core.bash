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

function audit_bash_history {
	local audit_file

	audit_file="$(audit_history_file_path)"
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

	echo "Usage: audit_bash_history [N|-f]"
	return 1
}
