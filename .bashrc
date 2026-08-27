#!/usr/bin/env bash
[[ $DOTFILES_DEBUG == "true" ]] && echo "[DOTFILE_DBG: Executing .BASHRC]"

# Interactive non-login shells enter here and load the full profile.
# ~/.bash_profile sources this file again at its very end (with
# __dotfiles_profile_loaded set) so that the local-additions tail below runs in
# every load path: interactive, login (bash -l / bash -lc) and agent mode.
# Non-interactive shells that were not started through ~/.bash_profile
# (e.g. `ssh host cmd`) still load nothing.
if [ -z "${__dotfiles_profile_loaded:-}" ]; then
	case $- in
		*i*) [ -n "$PS1" ] && source ~/.bash_profile ;;
	esac
	return
fi

# Everything below the marker is preserved by bootstrap.sh / dotfiles_update.
# Installers (claude, codex, cursor, nvm, conda, cargo, ...) append their
# PATH / init lines here; ~/.path_defaults already covers the common PATH dirs.
# >>> dotfiles: local additions below this line survive bootstrap/update >>>
