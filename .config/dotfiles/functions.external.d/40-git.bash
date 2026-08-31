#!/usr/bin/env bash
# Git-oriented helpers and interactive shell niceties.

function pull() {
	if [ ! -d .git ]; then
		echo "Not a Git repo."
		return 1
	fi

	if [ $# -eq 0 ]; then
		if [ "$(git status --short --branch | head -1 | grep -o '(no branch)')" = "(no branch)" ]; then
			echo "Not on a branch."
			return 1
		fi

		# If there is a tracked branch only pull that one
		git status --short --branch \
			| head -1 \
			| grep -oP '\.{3}\K\S+' \
			| sed 's|/| |' \
			| xargs git pull
	else
		git pull "$@"
	fi
}

function is_interactive_shell() {
	# https://www.gnu.org/software/bash/manual/html_node/Is-this-Shell-Interactive_003f.html
	[[ "$-" =~ "i" ]]
}

if is_interactive_shell; then
	# fzf git branch name; use like this: git checkout ^g^b
	bind '"\C-g\C-b": "$(git branch -a | cut -c 3- | fzf)\e\C-e"'
fi

# fzf
export FZF_CTRL_T_COMMAND="fd --type f"

function gfc {
	local origin_branch_name="$1"

	git fetch origin "$origin_branch_name"
	git checkout "$origin_branch_name"
	git reset --hard "origin/$origin_branch_name"
}

function gdv() {
	git diff --ignore-all-space "$@" | vim -R -
}

function get_default_branch() {
	if git branch | grep -q '^. main\s*$'; then
		echo main
	else
		echo master
	fi
}
