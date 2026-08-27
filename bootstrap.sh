#!/usr/bin/env bash

cd "$(dirname "${BASH_SOURCE}")";
DOTFILES_BOOTSTRAP_SOURCE_DIR="$(pwd -P)";

dotfiles_bootstrap_branch='main';
dotfiles_origin_head_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2> /dev/null || true)";
if [[ -n "$dotfiles_origin_head_ref" && "$dotfiles_origin_head_ref" == origin/* ]]; then
	dotfiles_bootstrap_branch="${dotfiles_origin_head_ref#origin/}";
fi;
git pull origin "$dotfiles_bootstrap_branch";

function _command_exists() {
	command -v "$1" > /dev/null 2>&1;
}

function _is_true() {
	case "${1:-}" in
		1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]) return 0 ;;
	esac;
	return 1;
}

function _run_with_privileges() {
	if [ "$EUID" -eq 0 ]; then
		"$@";
	elif _command_exists sudo; then
		sudo "$@";
	else
		echo "WARNING: Need elevated privileges to install packages, but sudo is not available.";
		return 1;
	fi;
}

function _has_bash_completion_loader() {
	local completion_sources=(
		/etc/profile.d/bash_completion.sh
		/etc/bash_completion
		/usr/share/bash-completion/bash_completion
		/usr/share/bash-completion/bash_completion.sh
		/usr/local/share/bash-completion/bash_completion
		/usr/local/etc/bash_completion
	);
	local completion_script;
	local brew_prefix;

	if _command_exists brew; then
		brew_prefix="$(brew --prefix 2> /dev/null)";
		if [ -n "$brew_prefix" ]; then
			completion_sources+=(
				"$brew_prefix/etc/profile.d/bash_completion.sh"
				"$brew_prefix/etc/bash_completion"
			);
		fi;
	fi;

	for completion_script in "${completion_sources[@]}"; do
		[ -r "$completion_script" ] && return 0;
	done;

	return 1;
}

function _install_bash_completion() {
	local os_name="$(uname -s)";

	case "$os_name" in
		Darwin)
			if _command_exists brew; then
				brew list bash-completion@2 > /dev/null 2>&1 || brew install bash-completion@2;
			else
				echo "WARNING: Homebrew is not installed; skipping bash-completion install on macOS.";
				return 1;
			fi
			;;
		Linux)
			if _command_exists apt-get; then
				_run_with_privileges apt-get update && _run_with_privileges apt-get install -y bash-completion;
			elif _command_exists dnf; then
				_run_with_privileges dnf install -y bash-completion;
			elif _command_exists yum; then
				_run_with_privileges yum install -y bash-completion;
			elif _command_exists pacman; then
				_run_with_privileges pacman -Sy --noconfirm bash-completion;
			elif _command_exists zypper; then
				_run_with_privileges zypper --non-interactive install bash-completion;
			elif _command_exists apk; then
				_run_with_privileges apk add bash-completion;
			elif _command_exists xbps-install; then
				_run_with_privileges xbps-install -Sy bash-completion;
			else
				echo "WARNING: Unsupported package manager. Install 'bash-completion' manually.";
				return 1;
			fi
			;;
		*)
			echo "WARNING: Unsupported OS '$os_name'. Install bash-completion manually.";
			return 1;
			;;
	esac
}

function ensure_bash_completion() {
	if _has_bash_completion_loader; then
		return 0;
	fi;

	echo "Bash completion loader not found. Attempting to install bash-completion...";
	if _install_bash_completion && _has_bash_completion_loader; then
		echo "bash-completion installed successfully.";
	else
		echo "WARNING: Could not verify bash-completion. Autocomplete may be limited.";
	fi;
}

function persist_dotfiles_repo_dir() {
	local persist_enabled="${DOTFILES_BOOTSTRAP_PERSIST_REPO_DIR:-true}";
	local marker_file="$HOME/.dotfiles_repo_dir";
	local marker_value="${DOTFILES_BOOTSTRAP_REPO_DIR_VALUE:-$DOTFILES_BOOTSTRAP_SOURCE_DIR}";

	if ! _is_true "$persist_enabled"; then
		return 0;
	fi;

	if [ -z "$marker_value" ]; then
		return 0;
	fi;

	printf '%s\n' "$marker_value" > "$marker_file";
}

DOTFILES_LOCAL_TAIL_MARKER='# >>> dotfiles: local additions below this line survive bootstrap/update >>>';

# Print everything after the local-additions marker of an installed rc file.
# Legacy installs without the marker fall back to the known last line of the
# old templates so installer appends made before this feature are kept too.
function _dotfiles_local_tail() {
	local file="$1";
	local marker_line='';

	[ -f "$file" ] || return 0;
	marker_line="$(grep -nF -- "$DOTFILES_LOCAL_TAIL_MARKER" "$file" | head -n 1 | cut -d: -f1)";
	if [ -z "$marker_line" ]; then
		case "$(basename "$file")" in
			.bashrc) marker_line="$(grep -nE 'source ~/.bash_profile' "$file" | head -n 1 | cut -d: -f1)" ;;
			.bash_profile) marker_line="$(grep -nE '^fi # end .*check$' "$file" | tail -n 1 | cut -d: -f1)" ;;
		esac;
	fi;
	[ -n "$marker_line" ] || return 0;
	tail -n +"$((marker_line + 1))" "$file";
}

function _dotfiles_restore_local_tail() {
	local file="$1";
	local tail_content="$2";
	local line_count;

	[ -n "${tail_content//[[:space:]]/}" ] || return 0;
	[ -f "$file" ] || return 0;
	printf '%s\n' "$tail_content" >> "$file";
	line_count="$(printf '%s\n' "$tail_content" | wc -l | tr -d ' ')";
	printf 'Preserved %s line(s) of local additions in %s\n' "$line_count" "$file";
}

function doIt() {
	local bashrc_tail bash_profile_tail;
	bashrc_tail="$(_dotfiles_local_tail ~/.bashrc)";
	bash_profile_tail="$(_dotfiles_local_tail ~/.bash_profile)";

	rsync --exclude ".git/" \
		--exclude ".DS_Store" \
		--exclude ".osx" \
		--exclude "*.sh" \
		--exclude "*.md" \
		--exclude "*.disabled" \
		--exclude "*.txt" \
		-avh --no-perms . ~;
	_dotfiles_restore_local_tail ~/.bashrc "$bashrc_tail";
	_dotfiles_restore_local_tail ~/.bash_profile "$bash_profile_tail";
	ensure_bash_completion;
	persist_dotfiles_repo_dir;

	if ! _is_true "${DOTFILES_BOOTSTRAP_NO_SOURCE_PROFILE:-false}"; then
		source ~/.bash_profile;
	fi;
}

if [ "$1" == "--force" -o "$1" == "-f" ]; then
	doIt;
else
	read -p "This may overwrite existing files in your home directory. Are you sure? (y/n) " -n 1;
	echo "";
	if [[ $REPLY =~ ^[Yy]$ ]]; then
		doIt;
	fi;
fi;
unset _command_exists _is_true _run_with_privileges _has_bash_completion_loader _install_bash_completion ensure_bash_completion persist_dotfiles_repo_dir doIt;
unset DOTFILES_BOOTSTRAP_SOURCE_DIR dotfiles_bootstrap_branch dotfiles_origin_head_ref;
