#!/usr/bin/env bash
# User-facing interactive functions and related command aliases.

if ! declare -F dotfiles_dbg > /dev/null; then
	function dotfiles_dbg {
		[[ "$DOTFILES_DEBUG" == "true" ]] && printf '[DOTFILE_DBG: %s]\n' "$*"
	}
fi

if [ -n "${_dotfiles_loader_root:-}" ]; then
	_dotfiles_external_dir="$_dotfiles_loader_root"
else
	_dotfiles_external_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_dotfiles_external_modules=(
	"${_dotfiles_external_dir}/functions.external.d/10-core.bash"
	"${_dotfiles_external_dir}/functions.external.d/20-dotfiles.bash"
	"${_dotfiles_external_dir}/functions.external.d/30-filesystem.bash"
	"${_dotfiles_external_dir}/functions.external.d/40-git.bash"
	"${_dotfiles_external_dir}/functions.external.d/50-network-media.bash"
)
_dotfiles_external_load_status=0

for _dotfiles_external_module in "${_dotfiles_external_modules[@]}"; do
	if [ ! -r "$_dotfiles_external_module" ] || [ ! -f "$_dotfiles_external_module" ]; then
		printf 'dotfiles: required external module is missing or unreadable: %s\n' "$_dotfiles_external_module" >&2
		_dotfiles_external_load_status=1
		break
	fi

	if ! source "$_dotfiles_external_module"; then
		printf 'dotfiles: failed to source required external module: %s\n' "$_dotfiles_external_module" >&2
		_dotfiles_external_load_status=1
		break
	fi
done

unset _dotfiles_external_module _dotfiles_external_modules _dotfiles_external_dir
if [ "$_dotfiles_external_load_status" -ne 0 ]; then
	unset _dotfiles_external_load_status
	return 1
fi
unset _dotfiles_external_load_status
