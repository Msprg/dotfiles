#!/bin/bash
export DOTFILES_DEBUG="false"

[[ $DOTFILES_DEBUG == "true" ]] && echo "[DOTFILE_DBG: --- S T A R T ---]"
[[ $DOTFILES_DEBUG == "true" ]] && echo "[DOTFILE_DBG: Executing .BASHRC]"


[ "$OSTYPE" = "linux-gnueabi" ] && export PS1="    \[\033[0;33m\]\w\[\033[0;37m\] \[\033[0;32m\]ε\[\033[0;37m\]  "
[ "$OSTYPE" = "linux-gnu" ] && export PS1="    \[\033[0;33m\]\w\[\033[0;37m\] \[\033[0;32m\]Ξ\[\033[0;37m\]  "
[[ $OSTYPE =~ ^darwin ]] && export PS1="    \[\033[0;33m\]\w\[\033[0;37m\] \[\033[0;35m\]ɀ\[\033[0;37m\]  "
[ "`whoami`" = "msprg" ] && export PS1="    \[\033[0;33m\]\w\[\033[0;37m\] \[\033[1;33m\]ω\[\033[0;37m\]  "

echo -n -e "\033]0;`whoami`@`hostname -f`\007"

# Cause the status of terminated background jobs to be reported immediately,
# rather than before printing the next primary prompt.
set -b


# Load the shell dotfiles, and then some:
# * ~/.path can be used to extend `$PATH`.
# * ~/.extra can be used for other settings you don’t want to commit.
for file in ~/.{path,bash_prompt,exports,functions,extra,systemspecific}; do
	[ -r "$file" ] && [ -f "$file" ] && source "$file";
done;
[ -r "$HOME/.aliases/bash/aliases" ] && [ -f "$HOME/.aliases/bash/aliases" ] && source "$HOME/.aliases/bash/aliases";
unset file;

shopt -s extglob
# keeps newlines in multi-line commands
shopt -s cmdhist
shopt -s lithist
# If set, the history list is appended to the file named by the value of the
# HISTFILE variable when the shell exits, rather than overwriting the file.
# Append to the Bash history file, rather than overwriting it
shopt -s histappend
# Case-insensitive globbing (used in pathname expansion)
shopt -s nocaseglob;
# Autocorrect typos in path names when using `cd`
shopt -s cdspell;
# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# Enable some Bash 4 features when possible:
# * `autocd`, e.g. `**/qux` will enter `./foo/bar/baz/qux`
# * Recursive globbing, e.g. `echo **/*.txt`
for option in autocd globstar; do
	shopt -s "$option" 2> /dev/null;
done;




# Add tab completion for many Bash commands.
completion_sources=(
	/etc/profile.d/bash_completion.sh
	/etc/bash_completion
	/usr/share/bash-completion/bash_completion
	/usr/share/bash-completion/bash_completion.sh
	/usr/local/share/bash-completion/bash_completion
	/usr/local/etc/bash_completion
);

if command -v brew &> /dev/null; then
	brew_prefix="$(brew --prefix 2> /dev/null)";
	if [ -n "$brew_prefix" ]; then
		completion_sources+=(
			"$brew_prefix/etc/profile.d/bash_completion.sh"
			"$brew_prefix/etc/bash_completion"
		);
	fi;
fi;

loaded_completion_script='false';
for completion_script in "${completion_sources[@]}"; do
	if [ -r "$completion_script" ]; then
		if [[ "$completion_script" =~ /etc/profile\.d/bash_completion\.sh$ ]]; then
			completion_compat_dir="${completion_script%/profile.d/bash_completion.sh}/bash_completion.d";
			[ -d "$completion_compat_dir" ] && export BASH_COMPLETION_COMPAT_DIR="$completion_compat_dir";
		fi;
		source "$completion_script";
		loaded_completion_script='true';
		break;
	fi;
done;

if [[ "$DOTFILES_DEBUG" == "true" ]] && [ "$loaded_completion_script" != 'true' ] && [ -d /usr/share/bash-completion/completions ]; then
	echo "[DOTFILE_DBG: completion definitions found in /usr/share/bash-completion/completions but no bash-completion loader script is installed]";
fi;

# `bash-completion` often lazy-loads Git completions; trigger a load if needed.
if ! type _git &> /dev/null && ! type __git_main &> /dev/null && type _completion_loader &> /dev/null; then
	_completion_loader git > /dev/null 2>&1;
fi;

# Fallback for systems that install Git completion without bash-completion.
if ! type _git &> /dev/null && ! type __git_main &> /dev/null; then
	git_completion_sources=(
		/etc/bash_completion.d/git
		/usr/share/bash-completion/completions/git
		/usr/local/etc/bash_completion.d/git
		/usr/local/share/bash-completion/completions/git
	);

	if [ -n "$brew_prefix" ]; then
		git_completion_sources+=(
			"$brew_prefix/etc/bash_completion.d/git-completion.bash"
			"$brew_prefix/share/bash-completion/completions/git"
		);
	fi;

	for git_completion_script in "${git_completion_sources[@]}"; do
		if [ -r "$git_completion_script" ]; then
			source "$git_completion_script";
			break;
		fi;
	done;
fi;

unset completion_sources completion_script completion_compat_dir;
unset git_completion_sources git_completion_script brew_prefix loaded_completion_script;

# yes, or maybe not?
# source /usr/local/etc/bash_completion

#SECTION - Autocompletion of Make targets BEGIN

function _makefile_targets {
    local curr_arg;
    local targets;

    # Find makefile targets available in the current directory
    targets=''
    if [[ -e "Makefile" ]]; then
        targets=$( \
            grep -oE '^[a-zA-Z0-9._-]+:' Makefile \
            | sed 's/://' \
            | tr '\n' ' ' \
        )
    fi

    # Filter targets based on user input to the bash completion
    curr_arg=${COMP_WORDS[COMP_CWORD]}
    COMPREPLY=( $(compgen -W "${targets[@]}" -- $curr_arg ) );
}
complete -F _makefile_targets make
complete -F _makefile_targets m

#!SECTION Autocompletion of Make targets END

# Enable tab completion for `g` by marking it as an alias for `git`
if type __git_complete &> /dev/null; then
	__git_complete g git;
elif type _git &> /dev/null; then
	complete -o default -o nospace -F _git g;
fi;

# Add tab completion for SSH hostnames based on ~/.ssh/config, ignoring wildcards
[ -e "$HOME/.ssh/config" ] && complete -o "default" -o "nospace" -W "$(grep "^Host" ~/.ssh/config | grep -v "[?*]" | cut -d " " -f2- | tr ' ' '\n')" scp sftp ssh;

# Add tab completion for `defaults read|write NSGlobalDomain`
# You could just use `-g` instead, but I like being explicit
#complete -W "NSGlobalDomain" defaults;
