#!/usr/bin/env bash

cd "$(dirname "${BASH_SOURCE[0]}")" || return 1 2> /dev/null || exit 1;
DOTFILES_BOOTSTRAP_SOURCE_DIR="$(pwd -P)";

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
	if _is_true "${DOTFILES_BOOTSTRAP_NO_SUDO:-false}" || [ "$EUID" -eq 0 ]; then
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

function _dotfiles_source_metadata() {
	local source_url='https://github.com/Msprg/dotFiles.git';
	local source_branch='main';
	local installed_commit='unknown';
	local update_mode='manual';
	local origin_head_ref='';
	local configured_url='';
	local tracked_commit='';

	if git -C "$DOTFILES_BOOTSTRAP_SOURCE_DIR" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
		configured_url="$(git -C "$DOTFILES_BOOTSTRAP_SOURCE_DIR" config --get remote.origin.url 2> /dev/null || true)";
		[ -n "$configured_url" ] && source_url="$configured_url";
		installed_commit="$(git -C "$DOTFILES_BOOTSTRAP_SOURCE_DIR" rev-parse HEAD 2> /dev/null || printf '%s' 'unknown')";
		if [ -n "$(git -C "$DOTFILES_BOOTSTRAP_SOURCE_DIR" status --porcelain 2> /dev/null)" ]; then
			installed_commit="${installed_commit}-dirty";
		fi;
		origin_head_ref="$(git -C "$DOTFILES_BOOTSTRAP_SOURCE_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2> /dev/null || true)";
		if [[ "$origin_head_ref" == origin/* ]]; then
			source_branch="${origin_head_ref#origin/}";
		else
			source_branch="$(git -C "$DOTFILES_BOOTSTRAP_SOURCE_DIR" branch --show-current 2> /dev/null || true)";
			[ -n "$source_branch" ] || source_branch='main';
		fi;
		tracked_commit="$(git -C "$DOTFILES_BOOTSTRAP_SOURCE_DIR" rev-parse "refs/remotes/origin/$source_branch" 2> /dev/null || true)";
		if [ "$installed_commit" = "$tracked_commit" ]; then
			update_mode='remote';
		fi;
	fi;

	printf '%s\n' "$source_url" "$source_branch" "$installed_commit" "$update_mode";
}

function _write_install_metadata() {
	local destination="$1";
	local scope="$2";
	local install_root="$3";
	local source_url source_branch installed_commit update_mode;
	local metadata_file;
	local profile_d_dir='';

	if [ "$scope" = 'system' ]; then
		profile_d_dir="${DOTFILES_SYSTEM_PROFILE_D_DIR:-/etc/profile.d}";
	fi;

	{
		IFS= read -r source_url;
		IFS= read -r source_branch;
		IFS= read -r installed_commit;
		IFS= read -r update_mode;
	} < <(_dotfiles_source_metadata);

	metadata_file="$(mktemp "${TMPDIR:-/tmp}/dotfiles-install.XXXXXX")" || return 1;
	{
		printf 'scope=%s\n' "$scope";
		printf 'install_root=%s\n' "$install_root";
		printf 'profile_d_dir=%s\n' "$profile_d_dir";
		printf 'source_url=%s\n' "$source_url";
		printf 'source_branch=%s\n' "$source_branch";
		printf 'installed_commit=%s\n' "$installed_commit";
		printf 'update_mode=%s\n' "$update_mode";
		printf 'installed_at=%s\n' "$(date +%s)";
	} > "$metadata_file";

	if [ "$scope" = 'system' ]; then
		_run_with_privileges install -m 0644 "$metadata_file" "$destination";
	else
		install -m 0644 "$metadata_file" "$destination";
	fi;
	local status=$?;
	rm -f "$metadata_file";
	return "$status";
}

function _install_system_profile_hook() {
	local install_root="$1";
	local profile_d_dir="$2";
	local hook_file="$profile_d_dir/dotfiles.sh";
	local hook_tmp escaped_root;

	escaped_root="$(printf '%q' "$install_root")";
	hook_tmp="$(mktemp "${TMPDIR:-/tmp}/dotfiles-profile.XXXXXX")" || return 1;
	{
		printf '%s\n' '# Managed by dotFiles bootstrap. Load the shared runtime for interactive Bash shells.';
		printf '%s\n' 'if [ -n "${BASH_VERSION:-}" ]; then';
		printf '%s\n' '  case "$-" in';
		printf '%s\n' '    *i*)';
		printf '      DOTFILES_CONFIG_DIR=%s\n' "$escaped_root";
		printf '%s\n' "      DOTFILES_INSTALL_SCOPE=system";
		printf '%s\n' '      export DOTFILES_CONFIG_DIR DOTFILES_INSTALL_SCOPE';
		printf '%s\n' '      if [ "${_DOTFILES_SYSTEM_PROFILE_LOADED:-}" != "$DOTFILES_CONFIG_DIR" ]; then';
		printf '%s\n' '        _DOTFILES_SYSTEM_PROFILE_LOADED="$DOTFILES_CONFIG_DIR"';
		printf '%s\n' '        . "$DOTFILES_CONFIG_DIR/.bash_profile"';
		printf '%s\n' '      fi';
		printf '%s\n' '      ;;';
		printf '%s\n' '  esac';
		printf '%s\n' 'fi';
	} > "$hook_tmp";

	_run_with_privileges mkdir -p "$profile_d_dir" \
		&& _run_with_privileges install -m 0644 "$hook_tmp" "$hook_file";
	local status=$?;
	rm -f "$hook_tmp";
	return "$status";
}

function _rsync_dotfiles() {
	local destination="$1";
	local privileged="$2";
	local -a rsync_args;
	shift 2;

	rsync_args=(
		--exclude ".git/"
		--exclude ".DS_Store"
		--exclude ".osx"
		--exclude "tests/"
		--exclude "init/"
		--exclude "*.sh"
		--exclude "*.md"
		--exclude "*.disabled"
		--exclude "*.txt"
		-avh --no-perms
		"$@"
		"$DOTFILES_BOOTSTRAP_SOURCE_DIR/"
		"$destination/"
	);

	if _is_true "$privileged"; then
		_run_with_privileges rsync "${rsync_args[@]}";
	else
		rsync "${rsync_args[@]}";
	fi;
}

function _install_systemwide() {
	local install_root="${DOTFILES_SYSTEM_INSTALL_ROOT:-/usr/local/share/dotfiles}";
	local profile_d_dir="${DOTFILES_SYSTEM_PROFILE_D_DIR:-/etc/profile.d}";

	if [ "$(uname -s)" != 'Linux' ] && [ -z "${DOTFILES_SYSTEM_PROFILE_D_DIR:-}" ]; then
		echo "System-wide installation currently requires Linux profile.d support. Use --user on this platform." >&2;
		return 1;
	fi;

	_run_with_privileges mkdir -p "$install_root" \
		&& _rsync_dotfiles "$install_root" 'true' --delete --delete-excluded \
		&& _run_with_privileges chmod -R a+rX "$install_root" \
		&& _write_install_metadata "$install_root/.dotfiles-install" 'system' "$install_root" \
		&& _install_system_profile_hook "$install_root" "$profile_d_dir";
}

function _install_user() {
	_rsync_dotfiles "$HOME" 'false' \
		&& _write_install_metadata "$HOME/.dotfiles-install" 'user' "$HOME";
}

function _legacy_user_install_detected() {
	[ -f "$HOME/.bash_profile" ] \
		&& grep -q 'Executing .BASH_PROFILE' "$HOME/.bash_profile" 2> /dev/null \
		&& { [ -f "$HOME/.functions" ] || [ -d "$HOME/.functions.internal.d" ]; }
}

function _migrate_legacy_user_install() {
	local backup_dir;
	local legacy_path;
	local legacy_paths=(
		"$HOME/.bash_profile"
		"$HOME/.bashrc"
		"$HOME/.bash_prompt"
		"$HOME/.dotfiles_features"
		"$HOME/.exports"
		"$HOME/.functions"
		"$HOME/.functions.internal.bash"
		"$HOME/.functions.external.bash"
		"$HOME/.functions.internal.d"
		"$HOME/.functions.external.d"
		"$HOME/.aliases"
		"$HOME/.dotfiles-install"
		"$HOME/.dotfiles_repo_dir"
	);
	backup_dir="$HOME/.dotfiles-user-install-backup-$(date +%Y%m%d-%H%M%S)";

	mkdir -p "$backup_dir" || return 1;
	for legacy_path in "${legacy_paths[@]}"; do
		[ -e "$legacy_path" ] || continue;
		mv "$legacy_path" "$backup_dir/" || return 1;
	done;

	printf 'Moved the legacy per-user shell installation to %s\n' "$backup_dir";
	printf '%s\n' 'Preserved user-local overrides: ~/.path, ~/.extra, ~/.systemspecific, and ~/.dotfiles_features.local.';
}

function _show_bootstrap_help() {
	printf '%s\n' \
		'Usage: bash bootstrap.sh [--system|--user] [--migrate-user] [--force]' \
		'' \
		'  --system  Install shared runtime under /usr/local/share/dotfiles (default).' \
		'  --user    Install into the current user home directory (legacy mode).' \
		'  --migrate-user  Back up and deactivate a detected legacy per-user shell install.' \
		'  --force   Skip the confirmation prompt.';
}

dotfiles_install_scope="${DOTFILES_INSTALL_SCOPE:-system}";
dotfiles_bootstrap_force='false';
dotfiles_migrate_user='false';
for bootstrap_arg in "$@"; do
	case "$bootstrap_arg" in
		--system) dotfiles_install_scope='system' ;;
		--user) dotfiles_install_scope='user' ;;
		--migrate-user) dotfiles_migrate_user='true' ;;
		--force|-f) dotfiles_bootstrap_force='true' ;;
		--help|-h) _show_bootstrap_help; return 0 2> /dev/null || exit 0 ;;
		*) printf 'Unknown bootstrap option: %s\n' "$bootstrap_arg" >&2; _show_bootstrap_help >&2; return 2 2> /dev/null || exit 2 ;;
	esac;
done;

if [ "$dotfiles_install_scope" != 'system' ] && [ "$dotfiles_install_scope" != 'user' ]; then
	printf 'Invalid installation scope: %s\n' "$dotfiles_install_scope" >&2;
	return 2 2> /dev/null || exit 2;
fi;

if ! _is_true "$dotfiles_bootstrap_force"; then
	if [ "$dotfiles_install_scope" = 'system' ]; then
		bootstrap_prompt="Install shared minimal-profile dotfiles for all users? (y/n) ";
	else
		bootstrap_prompt="Install dotfiles into $HOME? (y/n) ";
	fi;
	read -r -p "$bootstrap_prompt" -n 1 REPLY;
	echo "";
	[[ $REPLY =~ ^[Yy]$ ]] || { echo 'Installation cancelled.'; return 0 2> /dev/null || exit 0; };
fi;

if [ "$dotfiles_install_scope" = 'system' ]; then
	_install_systemwide || { printf 'System-wide dotfiles installation failed.\n' >&2; return 1 2> /dev/null || exit 1; };
	echo "Installed shared dotfiles in ${DOTFILES_SYSTEM_INSTALL_ROOT:-/usr/local/share/dotfiles}.";
	if _legacy_user_install_detected; then
		if _is_true "$dotfiles_migrate_user"; then
			_migrate_legacy_user_install || { printf 'Legacy per-user migration failed.\n' >&2; return 1 2> /dev/null || exit 1; };
		else
			printf '%s\n' \
				"WARNING: A legacy per-user dotFiles installation is still active in $HOME." \
				'It may override the shared minimal profile. Re-run with --migrate-user to back it up and deactivate it.';
		fi;
	fi;
	echo "Open a new login shell to activate the minimal profile.";
else
	_install_user || { printf 'Per-user dotfiles installation failed.\n' >&2; return 1 2> /dev/null || exit 1; };
	echo "Installed dotfiles in $HOME.";
	if ! _is_true "${DOTFILES_BOOTSTRAP_NO_SOURCE_PROFILE:-false}" && [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
		source "$HOME/.bash_profile";
	else
		echo "Open a new login shell to activate the minimal profile.";
	fi;
fi;

if ! _is_true "${DOTFILES_BOOTSTRAP_SKIP_COMPLETION:-false}"; then
	ensure_bash_completion;
fi;

unset -f _command_exists _is_true _run_with_privileges _has_bash_completion_loader _install_bash_completion ensure_bash_completion;
unset -f _dotfiles_source_metadata _write_install_metadata _install_system_profile_hook _rsync_dotfiles;
unset -f _install_systemwide _install_user _legacy_user_install_detected _migrate_legacy_user_install _show_bootstrap_help;
unset DOTFILES_BOOTSTRAP_SOURCE_DIR dotfiles_install_scope dotfiles_bootstrap_force dotfiles_migrate_user bootstrap_arg bootstrap_prompt REPLY;
