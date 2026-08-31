#!/usr/bin/env bash
# Internal dotfiles runtime functions (prompt hooks, history/env automation, shared helpers).

if ! declare -F dotfiles_dbg > /dev/null; then
	function dotfiles_dbg {
		[[ "$DOTFILES_DEBUG" == "true" ]] && printf '[DOTFILE_DBG: %s]\n' "$*"
	}
fi

if [ -n "${_dotfiles_loader_root:-}" ]; then
	_dotfiles_internal_dir="$_dotfiles_loader_root"
else
	_dotfiles_internal_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
_dotfiles_internal_modules=(
	"${_dotfiles_internal_dir}/functions.internal.d/00-common.bash"
	"${_dotfiles_internal_dir}/functions.internal.d/10-history.bash"
	"${_dotfiles_internal_dir}/functions.internal.d/20-env.bash"
	"${_dotfiles_internal_dir}/functions.internal.d/30-update.bash"
	"${_dotfiles_internal_dir}/functions.internal.d/40-prompt.bash"
)
_dotfiles_internal_load_status=0

for _dotfiles_internal_module in "${_dotfiles_internal_modules[@]}"; do
	if [ ! -r "$_dotfiles_internal_module" ] || [ ! -f "$_dotfiles_internal_module" ]; then
		printf 'dotfiles: required internal module is missing or unreadable: %s\n' "$_dotfiles_internal_module" >&2
		_dotfiles_internal_load_status=1
		break
	fi

	if ! source "$_dotfiles_internal_module"; then
		printf 'dotfiles: failed to source required internal module: %s\n' "$_dotfiles_internal_module" >&2
		_dotfiles_internal_load_status=1
		break
	fi
done

unset _dotfiles_internal_module _dotfiles_internal_modules _dotfiles_internal_dir
if [ "$_dotfiles_internal_load_status" -ne 0 ]; then
	unset _dotfiles_internal_load_status
	return 1
fi
unset _dotfiles_internal_load_status
