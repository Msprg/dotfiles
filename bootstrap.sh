#!/usr/bin/env bash
# dotFiles installer. Default: system-wide install for all users
# (/usr/local/share/dotfiles + /etc/profile.d hook). --user installs into the
# invoking user's $HOME with the runtime at ~/.config/dotfiles.
# May be executed (bash bootstrap.sh ...) or sourced.

cd "$(dirname "${BASH_SOURCE[0]}")" || return 1 2> /dev/null || exit 1;
DOTFILES_BOOTSTRAP_SOURCE_DIR="$(pwd -P)";
DOTFILES_HOME="${DOTFILES_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles}";
DOTFILES_LOCAL_HOME="${DOTFILES_LOCAL_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/dotfiles}";

# NOTE: no implicit `git pull` here any more — dotfiles_update owns updating
# (it clones fresh and re-runs this script); for a manual run, pull first.

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
		echo "WARNING: Need elevated privileges, but sudo is not available.";
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

# The /etc/profile.d hook deliberately has NO interactivity guard: profile.d
# runs for login shells only, and login+non-interactive is exactly the agent
# `bash -lc` population — bash_profile's agent guard routes those to the cheap
# agent path itself. An `case $- in *i*` here would leave agent shells with no
# runtime (and no agent audit) at all.
function _install_system_profile_hook() {
	local install_root="$1";
	local profile_d_dir="$2";
	local hook_file="$profile_d_dir/dotfiles.sh";
	local hook_tmp escaped_root;

	escaped_root="$(printf '%q' "$install_root")";
	hook_tmp="$(mktemp "${TMPDIR:-/tmp}/dotfiles-profile.XXXXXX")" || return 1;
	{
		printf '%s\n' '# Managed by dotFiles bootstrap. Loads the shared Bash runtime; the agent';
		printf '%s\n' '# guard inside routes interactive vs agent/non-interactive shells itself.';
		printf '%s\n' 'if [ -n "${BASH_VERSION:-}" ]; then';
		printf '  DOTFILES_HOME=%s\n' "$escaped_root";
		printf '%s\n' '  DOTFILES_INSTALL_SCOPE=system';
		printf '%s\n' '  export DOTFILES_HOME DOTFILES_INSTALL_SCOPE';
		printf '%s\n' '  if [ -z "${_DOTFILES_RUNTIME_LOADED:-}" ] && [ -r "$DOTFILES_HOME/bash_profile" ]; then';
		printf '%s\n' '    _DOTFILES_RUNTIME_LOADED="$DOTFILES_HOME"';
		printf '%s\n' '    . "$DOTFILES_HOME/bash_profile"';
		printf '%s\n' '  fi';
		printf '%s\n' 'fi';
	} > "$hook_tmp";

	_run_with_privileges mkdir -p "$profile_d_dir" \
		&& _run_with_privileges install -m 0644 "$hook_tmp" "$hook_file";
	local status=$?;
	rm -f "$hook_tmp";
	return "$status";
}

# Debian-family: interactive non-login shells read /etc/bash.bashrc and never
# run profile.d. Append a marker-delimited block there when the file exists
# (RHEL has no /etc/bash.bashrc; its /etc/bashrc already sources profile.d).
function _install_system_bashrc_hook() {
	local profile_d_dir="$1";
	local bashrc_file="${DOTFILES_SYSTEM_BASHRC_FILE:-/etc/bash.bashrc}";
	local marker='# >>> dotfiles: system runtime hook >>>';
	local block_tmp;

	[ -f "$bashrc_file" ] || return 0;
	grep -qF "$marker" "$bashrc_file" 2> /dev/null && return 0;

	block_tmp="$(mktemp "${TMPDIR:-/tmp}/dotfiles-bashrc.XXXXXX")" || return 1;
	{
		printf '\n%s\n' "$marker";
		printf '[ -r %q/dotfiles.sh ] && . %q/dotfiles.sh\n' "$profile_d_dir" "$profile_d_dir";
		printf '%s\n' '# <<< dotfiles: system runtime hook <<<';
	} > "$block_tmp";
	_run_with_privileges bash -c 'cat "$1" >> "$2"' _ "$block_tmp" "$bashrc_file";
	local status=$?;
	rm -f "$block_tmp";
	return "$status";
}

# Shared audit store: /var/log/dotfiles/audit, root-owned, mode 1733 —
# every user can create their own 0600 log inside, nobody can list or read
# the others'. install -d is idempotent and re-asserts mode/owner on re-runs.
function _install_audit_dir() {
	local audit_dir="${DOTFILES_SYSTEM_AUDIT_DIR:-/var/log/dotfiles/audit}";
	local audit_parent;
	audit_parent="$(dirname "$audit_dir")";

	if _is_true "${DOTFILES_BOOTSTRAP_NO_SUDO:-false}" && [ "$EUID" -ne 0 ]; then
		# Test fixtures: no privileges available, still create the shape.
		install -d -m 0755 "$audit_parent" && install -d -m 1733 "$audit_dir";
	else
		_run_with_privileges install -d -m 0755 -o root -g root "$audit_parent" \
			&& _run_with_privileges install -d -m 1733 -o root -g root "$audit_dir";
	fi;
}

# Sync the runtime directory (repo .config/dotfiles/ + init/) into a managed
# root. --delete keeps the root canonical; per-user state that may live in a
# user-scope root (features.local, agent_guard.local, repo_dir,
# .dotfiles-install) is excluded. System scope adds --delete-excluded so the
# shared root carries no stray user state at all (its .dotfiles-install is
# rewritten right afterwards).
function _rsync_runtime() {
	local install_root="$1";
	local privileged="$2";
	shift 2;
	# --no-owner --no-group: running as root would otherwise preserve the
	# source checkout's owner and hand the shared runtime to that user.
	local rsync_cmd=(rsync -avh --no-perms --no-owner --no-group --delete
		--exclude '*.local'
		--exclude 'repo_dir'
		--exclude '.dotfiles-install'
		"$@"
		"$DOTFILES_BOOTSTRAP_SOURCE_DIR/.config/dotfiles/" "$install_root/");

	if _is_true "$privileged"; then
		_run_with_privileges "${rsync_cmd[@]}" \
			&& _run_with_privileges rsync -avh --no-perms --no-owner --no-group --delete "$DOTFILES_BOOTSTRAP_SOURCE_DIR/init/" "$install_root/init/";
	else
		"${rsync_cmd[@]}" \
			&& rsync -avh --no-perms --no-owner --no-group --delete "$DOTFILES_BOOTSTRAP_SOURCE_DIR/init/" "$install_root/init/";
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
		&& _rsync_runtime "$install_root" 'true' --delete-excluded \
		&& _run_with_privileges chmod -R a+rX "$install_root" \
		&& _write_install_metadata "$install_root/.dotfiles-install" 'system' "$install_root" \
		&& _install_system_profile_hook "$install_root" "$profile_d_dir" \
		&& _install_system_bashrc_hook "$profile_d_dir" \
		&& _install_audit_dir;
}

# Installer appends below the rc markers (and a legacy ~/.path) are normally
# moved to ~/.systemspecific by $DOTFILES_HOME/local_additions at shell start.
# Run the same migration once before rsync so appends on legacy installs (no
# marker yet) are not lost.
function migrate_local_additions() {
	if [ -r ./.config/dotfiles/local_additions ]; then
		if ! declare -F dotfiles_dbg > /dev/null; then
			function dotfiles_dbg {
				[[ "${DOTFILES_DEBUG:-}" == "true" ]] && printf '[DOTFILE_DBG: %s]\n' "$*";
				return 0;
			}
		fi;
		source ./.config/dotfiles/local_additions;
		dotfiles_migrate_local_additions;
	fi;
}

# One-time migration of previous per-user layouts into the current one.
# Covers: the old flat layout (everything dotted directly in $HOME) and the
# never-released dotted module layout (~/.functions.*.d/, ~/.dotfiles-install).
# Private override files are moved into $DOTFILES_LOCAL_HOME, repo-owned files
# are removed (repo metadata only when identical to the repo copy).
function migrate_legacy_layout() {
	local old new legacy_file legacy_dir;
	local legacy_repo_files=(
		.bash_prompt .exports .functions .functions.external.bash .functions.internal.bash
		.dotfiles_features .dotfiles_features.local.example
		.dotfiles_agent_guard .dotfiles_agent_guard.local.example
		.dotfiles_agent_audit .dotfiles_local_additions .path_defaults
		.dotfiles-install
	);

	mkdir -p "$DOTFILES_LOCAL_HOME";

	while IFS=: read -r old new; do
		if [ -e "$HOME/$old" ] && [ ! -e "$DOTFILES_LOCAL_HOME/$new" ]; then
			mv "$HOME/$old" "$DOTFILES_LOCAL_HOME/$new" && printf 'Moved ~/%s -> %s/%s\n' "$old" "${DOTFILES_LOCAL_HOME/#$HOME/\~}" "$new";
		fi;
	done <<-'EOF'
		.dotfiles_features.local:features.local
		.dotfiles_agent_guard.local:agent_guard.local
		.dotfiles_repo_dir:repo_dir
	EOF

	for legacy_file in "${legacy_repo_files[@]}"; do
		if [ -e "$HOME/$legacy_file" ] && [ ! -d "$HOME/$legacy_file" ]; then
			rm -f "$HOME/$legacy_file" && printf 'Removed legacy ~/%s\n' "$legacy_file";
		fi;
	done;
	for legacy_dir in .functions.internal.d .functions.external.d; do
		if [ -d "$HOME/$legacy_dir" ]; then
			rm -rf "$HOME/$legacy_dir" && printf 'Removed legacy ~/%s/\n' "$legacy_dir";
		fi;
	done;
	if [ -d "$HOME/.aliases/bash" ]; then
		rm -rf "$HOME/.aliases/bash" && printf 'Removed legacy ~/.aliases/bash\n';
		rmdir "$HOME/.aliases" 2> /dev/null || true;
	fi;

	# Repo metadata that older bootstraps copied into $HOME: only remove when
	# it is byte-identical to the repo copy (i.e. not the user's own file).
	for legacy_file in .gitignore .gitattributes; do
		if [ -f "$HOME/$legacy_file" ] && [ -f "./$legacy_file" ] && cmp -s "$HOME/$legacy_file" "./$legacy_file"; then
			rm -f "$HOME/$legacy_file" && printf 'Removed ~/%s (repo metadata copied by an older bootstrap)\n' "$legacy_file";
		fi;
	done;
	if [ -d "$HOME/init" ] && [ -d ./init ]; then
		for legacy_file in ./init/*; do
			[ -f "$legacy_file" ] || continue;
			if [ -f "$HOME/init/${legacy_file##*/}" ] && cmp -s "$legacy_file" "$HOME/init/${legacy_file##*/}"; then
				rm -f "$HOME/init/${legacy_file##*/}";
			fi;
		done;
		rmdir "$HOME/init" 2> /dev/null && printf 'Removed ~/init (repo samples copied by an older bootstrap)\n';
	fi;
}

function persist_dotfiles_repo_dir() {
	local persist_enabled="${DOTFILES_BOOTSTRAP_PERSIST_REPO_DIR:-true}";
	local marker_file="$DOTFILES_LOCAL_HOME/repo_dir";
	local marker_value="${DOTFILES_BOOTSTRAP_REPO_DIR_VALUE:-$DOTFILES_BOOTSTRAP_SOURCE_DIR}";

	if ! _is_true "$persist_enabled"; then
		return 0;
	fi;

	if [ -z "$marker_value" ]; then
		return 0;
	fi;

	mkdir -p "$DOTFILES_LOCAL_HOME";
	printf '%s\n' "$marker_value" > "$marker_file";
}

function _install_user() {
	if [ -e "${DOTFILES_SYSTEM_PROFILE_D_DIR:-/etc/profile.d}/dotfiles.sh" ]; then
		echo "NOTE: a system-wide dotfiles hook exists at ${DOTFILES_SYSTEM_PROFILE_D_DIR:-/etc/profile.d}/dotfiles.sh;";
		echo "      it loads first in login shells and this per-user install will be skipped there.";
	fi;

	migrate_local_additions;
	migrate_legacy_layout;
	rsync --exclude ".git/" \
		--exclude ".DS_Store" \
		--exclude ".osx" \
		--exclude ".gitignore" \
		--exclude ".gitattributes" \
		--exclude ".config/" \
		--exclude "init/" \
		--exclude "tests/" \
		--exclude "*.sh" \
		--exclude "*.md" \
		--exclude "*.disabled" \
		--exclude "*.txt" \
		-avh --no-perms . ~ \
		&& mkdir -p "$DOTFILES_LOCAL_HOME" \
		&& _rsync_runtime "$DOTFILES_LOCAL_HOME" 'false' \
		&& _write_install_metadata "$DOTFILES_LOCAL_HOME/.dotfiles-install" 'user' "$DOTFILES_LOCAL_HOME" \
		&& persist_dotfiles_repo_dir;
}

# Under `sudo bash bootstrap.sh` $HOME is root's home, but --migrate-user is
# meant for the INVOKING user's install: resolve the migration target from
# SUDO_USER when running as root.
function _dotfiles_migration_home() {
	local target_user="${SUDO_USER:-}";
	local target_home='';

	if [ "$EUID" -eq 0 ] && [ -n "$target_user" ] && [ "$target_user" != 'root' ]; then
		target_home="$(getent passwd "$target_user" 2> /dev/null | cut -d: -f6)";
	fi;
	printf '%s\n' "${target_home:-$HOME}";
}

function _dotfiles_migration_user() {
	if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != 'root' ]; then
		printf '%s\n' "$SUDO_USER";
	else
		id -un;
	fi;
}

function _legacy_user_install_detected() {
	local target_home;
	target_home="$(_dotfiles_migration_home)";
	[ -f "$target_home/.bash_profile" ] || return 1;
	grep -qE 'Executing \.BASH_PROFILE|DOTFILES_HOME' "$target_home/.bash_profile" 2> /dev/null || return 1;
	[ -e "$target_home/.functions" ] || [ -d "$target_home/.functions.internal.d" ] || [ -d "$target_home/.config/dotfiles" ];
}

# Deactivate a per-user install after a system-wide one. Moves ONLY files
# proven to be ours into a timestamped backup dir; a distro-default or
# hand-written rc file is left untouched (with a notice). ~/.path, ~/.extra,
# ~/.systemspecific and every *.local override stay in place.
function _migrate_legacy_user_install() {
	local target_home target_user target_local_home;
	target_home="$(_dotfiles_migration_home)";
	target_user="$(_dotfiles_migration_user)";
	target_local_home="${target_home}/.config/dotfiles";
	if [ "$target_home" = "$HOME" ]; then
		target_local_home="$DOTFILES_LOCAL_HOME";
	fi;
	local backup_dir="$target_home/.dotfiles-user-install-backup-$(date +%Y%m%d-%H%M%S)";
	local moved_any='false' entry;
	local home_artifacts=(
		.bash_prompt .dotfiles_features .dotfiles_features.local.example .exports
		.functions .functions.internal.bash .functions.external.bash
		.functions.internal.d .functions.external.d .aliases
		.dotfiles-install .dotfiles_repo_dir .path_defaults
		.dotfiles_agent_guard .dotfiles_agent_guard.local.example
		.dotfiles_agent_audit .dotfiles_local_additions
	);
	local runtime_artifacts=(
		bash_profile agent_guard agent_guard.local.example agent_audit
		path_defaults local_additions exports features features.local.example
		prompt functions functions.internal.bash functions.external.bash
		functions.internal.d functions.external.d aliases .dotfiles-install
	);

	# Salvage installer appends below the rc markers before touching rc files.
	# (Only meaningful when migrating the current $HOME; local_additions works
	# on $HOME by design.)
	if [ "$target_home" = "$HOME" ]; then
		migrate_local_additions;
	fi;

	mkdir -p "$backup_dir" || return 1;

	function _backup_move() {
		local path="$1" label="$2";
		[ -e "$path" ] || return 0;
		mv "$path" "$backup_dir/$label" && moved_any='true' \
			&& printf 'Moved %s -> %s/%s\n' "${path/#$target_home/\~}" "${backup_dir/#$target_home/\~}" "$label";
	}

	if [ -f "$target_home/.bash_profile" ]; then
		if grep -qE 'Executing \.BASH_PROFILE|DOTFILES_HOME' "$target_home/.bash_profile" 2> /dev/null; then
			_backup_move "$target_home/.bash_profile" '.bash_profile';
		else
			echo "NOTE: ~/.bash_profile does not look dotfiles-managed; leaving it in place.";
		fi;
	fi;
	if [ -f "$target_home/.bashrc" ]; then
		if grep -qE 'Executing \.BASHRC' "$target_home/.bashrc" 2> /dev/null; then
			_backup_move "$target_home/.bashrc" '.bashrc';
		else
			echo "NOTE: ~/.bashrc does not look dotfiles-managed; leaving it in place.";
		fi;
	fi;

	for entry in "${home_artifacts[@]}"; do
		_backup_move "$target_home/$entry" "$entry";
	done;
	if [ -d "$target_local_home" ]; then
		mkdir -p "$backup_dir/config-dotfiles";
		for entry in "${runtime_artifacts[@]}"; do
			[ -e "$target_local_home/$entry" ] || continue;
			mv "$target_local_home/$entry" "$backup_dir/config-dotfiles/$entry" && moved_any='true' \
				&& printf 'Moved %s/%s -> backup\n' "${target_local_home/#$target_home/\~}" "$entry";
		done;
	fi;

	# Restore distro defaults so interactive shells keep normal behavior.
	if [ ! -f "$target_home/.bashrc" ] && [ -f /etc/skel/.bashrc ]; then
		cp /etc/skel/.bashrc "$target_home/.bashrc" && echo "Restored ~/.bashrc from /etc/skel.";
	fi;
	if [ ! -f "$target_home/.bash_profile" ] && [ -f /etc/skel/.bash_profile ]; then
		cp /etc/skel/.bash_profile "$target_home/.bash_profile" && echo "Restored ~/.bash_profile from /etc/skel.";
	fi;
	# Everything this migration created must belong to the target user, not
	# root: a root-owned rc file or backup dir would lock the user out of
	# their own configuration.
	if [ "$EUID" -eq 0 ] && [ "$target_user" != 'root' ]; then
		chown -R "$target_user" "$backup_dir" 2> /dev/null;
		[ -f "$target_home/.bashrc" ] && chown "$target_user" "$target_home/.bashrc" 2> /dev/null;
		[ -f "$target_home/.bash_profile" ] && chown "$target_user" "$target_home/.bash_profile" 2> /dev/null;
	fi;

	unset -f _backup_move;
	if [ "$moved_any" = 'true' ]; then
		printf 'Legacy per-user install deactivated; backup in %s\n' "${backup_dir/#$HOME/\~}";
		printf '%s\n' 'Preserved user-local overrides: ~/.extra, ~/.systemspecific, and everything *.local in ~/.config/dotfiles.';
	else
		rmdir "$backup_dir" 2> /dev/null || true;
		echo "No legacy per-user install artifacts found to migrate.";
	fi;
}

function _show_bootstrap_help() {
	printf '%s\n' \
		'Usage: bash bootstrap.sh [--system|--user] [--migrate-user] [--force|-f] [--help]' \
		'  --system        install shared runtime for all users (default)' \
		'                  -> /usr/local/share/dotfiles + /etc/profile.d/dotfiles.sh + /var/log/dotfiles/audit' \
		'  --user          install for the invoking user only (~ + ~/.config/dotfiles)' \
		'  --migrate-user  with --system: back up and deactivate an existing per-user install' \
		'  --force, -f     skip the confirmation prompt';
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
		*)
			printf 'Unknown bootstrap option: %s\n' "$bootstrap_arg" >&2;
			_show_bootstrap_help >&2;
			return 2 2> /dev/null || exit 2;
			;;
	esac;
done;
case "$dotfiles_install_scope" in
	system|user) ;;
	*)
		printf 'Invalid DOTFILES_INSTALL_SCOPE: %s (expected system or user)\n' "$dotfiles_install_scope" >&2;
		return 2 2> /dev/null || exit 2;
		;;
esac;
if [ "$dotfiles_migrate_user" = 'true' ] && [ "$dotfiles_install_scope" = 'user' ]; then
	echo '--migrate-user requires --system (it deactivates a per-user install after a shared one).' >&2;
	return 2 2> /dev/null || exit 2;
fi;

if [ "$dotfiles_bootstrap_force" != 'true' ]; then
	if [ "$dotfiles_install_scope" = 'system' ]; then
		read -r -p "Install dotfiles SYSTEM-WIDE for all users under ${DOTFILES_SYSTEM_INSTALL_ROOT:-/usr/local/share/dotfiles}? (y/n) [--user for a per-user install] ";
	else
		read -r -p "Install dotfiles for $(id -un) into $HOME (runtime in ${DOTFILES_LOCAL_HOME/#$HOME/\~})? (y/n) ";
	fi;
	if ! [[ "$REPLY" =~ ^[Yy]$ ]]; then
		echo 'Aborted.';
		return 0 2> /dev/null || exit 0;
	fi;
fi;

dotfiles_bootstrap_status=0;
if [ "$dotfiles_install_scope" = 'system' ]; then
	if _install_systemwide; then
		if [ "$dotfiles_migrate_user" = 'true' ]; then
			if _legacy_user_install_detected || [ -d "$(_dotfiles_migration_home)/.config/dotfiles" ]; then
				_migrate_legacy_user_install || dotfiles_bootstrap_status=1;
			else
				echo 'No per-user install detected; nothing to migrate.';
			fi;
		elif _legacy_user_install_detected; then
			echo 'WARNING: a per-user dotfiles install is still active in your $HOME and loads';
			echo '         instead of the shared runtime. Re-run with --system --migrate-user to back it up.';
		fi;
	else
		dotfiles_bootstrap_status=1;
	fi;
else
	_install_user || dotfiles_bootstrap_status=1;
fi;

if [ "$dotfiles_bootstrap_status" -eq 0 ] && ! _is_true "${DOTFILES_BOOTSTRAP_SKIP_COMPLETION:-false}"; then
	ensure_bash_completion;
fi;

if [ "$dotfiles_bootstrap_status" -eq 0 ] \
	&& [ "$dotfiles_install_scope" = 'user' ] \
	&& [[ "${BASH_SOURCE[0]}" != "$0" ]] \
	&& ! _is_true "${DOTFILES_BOOTSTRAP_NO_SOURCE_PROFILE:-false}"; then
	source ~/.bash_profile;
fi;

unset -f _command_exists _is_true _run_with_privileges _has_bash_completion_loader \
	_install_bash_completion ensure_bash_completion _dotfiles_source_metadata \
	_write_install_metadata _install_system_profile_hook _install_system_bashrc_hook \
	_install_audit_dir _rsync_runtime _install_systemwide migrate_local_additions \
	migrate_legacy_layout persist_dotfiles_repo_dir _install_user \
	_legacy_user_install_detected _migrate_legacy_user_install _show_bootstrap_help \
	_dotfiles_migration_home _dotfiles_migration_user 2> /dev/null;
dotfiles_bootstrap_rc="$dotfiles_bootstrap_status";
unset DOTFILES_BOOTSTRAP_SOURCE_DIR dotfiles_install_scope dotfiles_bootstrap_force \
	dotfiles_migrate_user bootstrap_arg dotfiles_bootstrap_status;
if [ "${dotfiles_bootstrap_rc}" -ne 0 ]; then
	unset dotfiles_bootstrap_rc;
	return 1 2> /dev/null || exit 1;
fi;
unset dotfiles_bootstrap_rc;
