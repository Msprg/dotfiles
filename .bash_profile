#!/usr/bin/env bash
# Thin stub: the real runtime lives in $DOTFILES_HOME/bash_profile
# (~/.config/dotfiles for a per-user install, /usr/local/share/dotfiles for a
# system-wide one — the /etc/profile.d hook of a system install sets
# DOTFILES_HOME first and loads the runtime itself; the guard below keeps the
# two entry points from double-loading in one shell). Use `reload` after
# changing dotfiles; a plain `source ~/.bash_profile` in an already-loaded
# shell is a no-op by design.
export DOTFILES_HOME="${DOTFILES_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles}"
if [ -z "${_DOTFILES_RUNTIME_LOADED:-}" ] && [ -r "$DOTFILES_HOME/bash_profile" ]; then
	_DOTFILES_RUNTIME_LOADED="$DOTFILES_HOME"
	source "$DOTFILES_HOME/bash_profile"
fi

# Installers append below this marker; $DOTFILES_HOME/local_additions moves
# such lines into ~/.systemspecific at the next shell start. Do not edit above.
# >>> dotfiles: local additions below this line survive bootstrap/update >>>
