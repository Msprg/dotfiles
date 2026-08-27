#!/usr/bin/env bash
# Dotfiles management and shell reload helpers.

function dotfiles_profile {
	local requested_profile="$1"
	local local_features_file="$HOME/.dotfiles_features.local"
	local tmpfile

	case "$requested_profile" in
		''|show|current)
			dotfiles_dbg "dotfiles_profile show requested"
			echo "Session profile: ${DOTFILES_FEATURE_PROFILE:-minimal}"
			if [ -f "$local_features_file" ]; then
				if grep -qE '^[[:space:]]*DOTFILES_FEATURE_PROFILE=' "$local_features_file"; then
					echo "Local override ($(basename "$local_features_file")):"
					grep -E '^[[:space:]]*DOTFILES_FEATURE_PROFILE=' "$local_features_file" | tail -n 1
				else
					echo "Local override file exists, but no active DOTFILES_FEATURE_PROFILE line is set."
				fi
			else
				echo "No local override file found."
			fi
			;;
		full|light|minimal)
			dotfiles_dbg "dotfiles_profile set requested -> $requested_profile"
			if [ ! -f "$local_features_file" ]; then
				cat > "$local_features_file" << 'EOF'
# Local dotfiles feature overrides.
# Uncomment or set the profile you want:
# DOTFILES_FEATURE_PROFILE=full
# DOTFILES_FEATURE_PROFILE=light
# DOTFILES_FEATURE_PROFILE=minimal
# Choose command duration start hook:
# DOTFILES_FEATURE_TRACK_COMMAND_DURATION_METHOD=auto
# DOTFILES_FEATURE_TRACK_COMMAND_DURATION_METHOD=ps0
# DOTFILES_FEATURE_TRACK_COMMAND_DURATION_METHOD=debug
EOF
			fi
			tmpfile="$(mktemp)" || return 1
			awk -v profile="$requested_profile" '
				BEGIN { profile_set=0 }
				/^[[:space:]]*DOTFILES_FEATURE_PROFILE=/ {
					if (profile_set == 0) {
						print "DOTFILES_FEATURE_PROFILE=" profile
						profile_set=1
					}
					next
				}
				{ print }
				END {
					if (profile_set == 0) {
						print "DOTFILES_FEATURE_PROFILE=" profile
					}
				}
			' "$local_features_file" > "$tmpfile" && mv "$tmpfile" "$local_features_file"
			echo "Set profile to '$requested_profile' in $local_features_file"
			echo "Run: reload"
			;;
		reset|default)
			dotfiles_dbg "dotfiles_profile reset requested"
			if [ ! -f "$local_features_file" ]; then
				echo "No local profile override file to reset at $local_features_file"
				return 0
			fi
			tmpfile="$(mktemp)" || return 1
			awk '
				!/^[[:space:]]*DOTFILES_FEATURE_PROFILE=/
			' "$local_features_file" > "$tmpfile" && mv "$tmpfile" "$local_features_file"
			echo "Removed active DOTFILES_FEATURE_PROFILE override from $local_features_file"
			echo "Run: reload"
			;;
		*)
			echo "Usage: dotfiles_profile [show|full|light|minimal|reset]"
			return 1
			;;
	esac
}

function dotfiles_update {
	local allow_remote_replace='false'
	local canonical_repo_url="https://github.com/Msprg/dotFiles.git"
	local clone_url="$canonical_repo_url"
	local target_branch='main'
	local install_scope="${DOTFILES_INSTALL_SCOPE:-user}"
	local install_root="${DOTFILES_CONFIG_DIR:-$HOME}"
	local profile_d_dir="${DOTFILES_SYSTEM_PROFILE_D_DIR:-/etc/profile.d}"
	local temp_dir workspace_dir bootstrap_script synced_commit
	local bootstrap_args=(--force)

	case "${1:-}" in
		'') ;;
		--remote) allow_remote_replace='true' ;;
		*)
			echo "Usage: dotfiles_update [--remote]" >&2
			return 1
			;;
	esac

	if declare -F __dotfiles_read_install_metadata > /dev/null \
		&& __dotfiles_read_install_metadata; then
		install_scope="${__dotfiles_install_scope:-$install_scope}"
		install_root="${__dotfiles_install_root:-$install_root}"
		profile_d_dir="${__dotfiles_install_profile_d_dir:-$profile_d_dir}"
		clone_url="${__dotfiles_install_source_url:-$canonical_repo_url}"
		target_branch="${__dotfiles_install_source_branch:-main}"
		if [ "${__dotfiles_install_update_mode:-remote}" != 'remote' ] \
			&& [ "$allow_remote_replace" != 'true' ]; then
			printf '%s\n' \
				'dotfiles_update: this installation came from a modified or non-tracking checkout.' \
				'Reinstall from a clean tracked commit, or run dotfiles_update --remote to explicitly replace it with the configured remote branch.' >&2
			return 1
		fi
	fi

	case "$install_scope" in
		system) bootstrap_args+=(--system) ;;
		user) bootstrap_args+=(--user) ;;
		*)
			echo "dotfiles_update: unsupported installation scope '$install_scope'" >&2
			return 1
			;;
	esac

	temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-update.XXXXXX")" || {
		echo "dotfiles_update: could not create temp workspace" >&2
		return 1
	}
	workspace_dir="$temp_dir/dotFiles"

	echo "Fetching dotfiles update from $clone_url (branch: $target_branch) ..."
	if ! git clone --quiet --depth 1 --branch "$target_branch" "$clone_url" "$workspace_dir"; then
		rm -rf "$temp_dir"
		echo "dotfiles_update: clone failed from $clone_url (branch: $target_branch)" >&2
		return 1
	fi

	bootstrap_script="$workspace_dir/bootstrap.sh"
	if [ ! -r "$bootstrap_script" ]; then
		rm -rf "$temp_dir"
		echo "dotfiles_update: bootstrap script not found at $bootstrap_script" >&2
		return 1
	fi

	if ! DOTFILES_BOOTSTRAP_NO_SOURCE_PROFILE='true' \
		DOTFILES_BOOTSTRAP_SKIP_COMPLETION='true' \
		DOTFILES_SYSTEM_INSTALL_ROOT="$install_root" \
		DOTFILES_SYSTEM_PROFILE_D_DIR="$profile_d_dir" \
		bash "$bootstrap_script" "${bootstrap_args[@]}"; then
		rm -rf "$temp_dir"
		echo "dotfiles_update: installation failed" >&2
		return 1
	fi

	synced_commit="$(git -C "$workspace_dir" rev-parse HEAD 2> /dev/null || true)"
	rm -rf "$temp_dir"

	# Refresh this user's cache immediately. Other users invalidate stale cache
	# entries when their next shell observes the new installed commit.
	if [ -n "$synced_commit" ] && declare -F __dotfiles_write_update_state > /dev/null; then
		__dotfiles_write_update_state "up_to_date" "$synced_commit" "$synced_commit" "$(date +%s)" ""
	fi

	echo "Dotfiles updated. Reloading shell..."
	reload
}

unalias reload debug_reload safe_reload 2>/dev/null

# Reload the shell (i.e. invoke as a login shell)
function reload {
	_dotfiles_unset_runtime_env
	unset DOTFILES_DEBUG DOTFILES_DEBUG_PROMPT_VERBOSE BASH_SAFE_MODE
	exec "${SHELL:-bash}" -l
}

# Reload the shell without loading dotfiles customizations (safe mode)
function safe_reload {
	_dotfiles_unset_runtime_env
	unset DOTFILES_DEBUG DOTFILES_DEBUG_PROMPT_VERBOSE
	export BASH_SAFE_MODE=true
	exec bash --login
}

# Reload the shell with dotfiles debugging
function debug_reload {
	_dotfiles_unset_runtime_env
	unset BASH_SAFE_MODE DOTFILES_DEBUG_PROMPT_VERBOSE
	export DOTFILES_DEBUG=true
	exec bash --login
}
