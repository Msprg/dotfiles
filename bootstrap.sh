#!/usr/bin/env bash

cd "$(dirname "${BASH_SOURCE}")";

git pull origin main;

function _command_exists() {
	command -v "$1" > /dev/null 2>&1;
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

function doIt() {
	rsync --exclude ".git/" \
		--exclude ".DS_Store" \
		--exclude ".osx" \
		--exclude "*.sh" \
		--exclude "*.md" \
		--exclude "*.disabled" \
		--exclude "*.txt" \
		-avh --no-perms . ~;
	ensure_bash_completion;
	source ~/.bash_profile;
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
unset _command_exists _run_with_privileges _has_bash_completion_loader _install_bash_completion ensure_bash_completion doIt;
