#!/bin/bash

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




# Add tab completion for many Bash commands
if which brew &> /dev/null && [ -r "$(brew --prefix)/etc/profile.d/bash_completion.sh" ]; then
	# Ensure existing Homebrew v1 completions continue to work
	export BASH_COMPLETION_COMPAT_DIR="$(brew --prefix)/etc/bash_completion.d";
	source "$(brew --prefix)/etc/profile.d/bash_completion.sh";
elif [ -f /etc/bash_completion ]; then
	source /etc/bash_completion;
fi;

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
if type _git &> /dev/null; then
	complete -o default -o nospace -F _git g;
fi;

# Add tab completion for SSH hostnames based on ~/.ssh/config, ignoring wildcards
[ -e "$HOME/.ssh/config" ] && complete -o "default" -o "nospace" -W "$(grep "^Host" ~/.ssh/config | grep -v "[?*]" | cut -d " " -f2- | tr ' ' '\n')" scp sftp ssh;

# Add tab completion for `defaults read|write NSGlobalDomain`
# You could just use `-g` instead, but I like being explicit
#complete -W "NSGlobalDomain" defaults;

