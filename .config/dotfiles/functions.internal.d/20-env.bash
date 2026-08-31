#!/usr/bin/env bash
# Per-directory environment loading.

function unload_dot_env_vars {
	if [ "${#__dotfiles_loaded_env_vars[@]}" -gt 0 ]; then
		unset "${__dotfiles_loaded_env_vars[@]}"
	fi
	__dotfiles_loaded_env_vars=()
}

function get_dot_env_signature {
	local env_file="$1"
	local checksum size remainder

	[ -f "$env_file" ] || return 1
	read -r checksum size remainder < <(cksum < "$env_file")
	printf '%s:%s\n' "$checksum" "$size"
}

function check_for_dot_env {
	local current_env_file="$PWD/.env"
	local env_signature source_status=0
	local env_vars=()
	local line

	if [ ! -f "$current_env_file" ]; then
		if [ -n "${__dotfiles_loaded_env_file:-}" ]; then
			unload_dot_env_vars
			__dotfiles_loaded_env_file=''
			__dotfiles_loaded_env_signature=''
		fi
		return 0
	fi

	env_signature="$(get_dot_env_signature "$current_env_file")" || return 1
	if [[ "${__dotfiles_loaded_env_file:-}" == "$current_env_file" && "${__dotfiles_loaded_env_signature:-}" == "$env_signature" ]]; then
		return 0
	fi

	if [ -n "${__dotfiles_loaded_env_file:-}" ]; then
		unload_dot_env_vars
	fi
	__dotfiles_loaded_env_file=''
	__dotfiles_loaded_env_signature=''

	while IFS= read -r line || [ -n "$line" ]; do
		if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]]; then
			env_vars+=("${BASH_REMATCH[2]}")
		fi
	done < "$current_env_file"

	set -o allexport
	source "$current_env_file" || source_status=$?
	set +o allexport
	if [ "$source_status" -ne 0 ]; then
		return "$source_status"
	fi

	__dotfiles_loaded_env_vars=("${env_vars[@]}")
	__dotfiles_loaded_env_file="$current_env_file"
	__dotfiles_loaded_env_signature="$env_signature"
	echo "Loaded .env"
}
