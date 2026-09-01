#!/usr/bin/env bash
# Shared helpers used by the internal and external function layers.

function _dotfiles_unset_runtime_env {
	local var_name

	while IFS= read -r var_name; do
		unset "$var_name"
	done < <(compgen -v | grep -E '^DOTFILES_FEATURE_')

	unset var_name
	unset PS0 PS1 PS2 PS4 PROMPT_COMMAND
	unset DOTFILES_AGENT DOTFILES_AGENT_MODE DOTFILES_AGENT_MODE_ACTIVE
}

function _command_exists() {
#	_about 'checks for existence of a command'
#	_param '1: command to check'
#	_param '2: (optional) log message to include when command not found'
#	_example '$ _command_exists ls && echo exists'
#	_group 'lib'
	local msg="${2:-Command '$1' does not exist}"
	if type -t "$1" > /dev/null; then
		return 0
	else
		#_log_debug "$msg"
		return 1
	fi
}
