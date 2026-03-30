#!/usr/bin/env bash
# Dotfiles management and shell reload helpers.

function dotfiles_profile {
	local requested_profile="$1"
	local local_features_file="$HOME/.dotfiles_features.local"
	local tmpfile

	case "$requested_profile" in
		''|show|current)
			dotfiles_dbg "dotfiles_profile show requested"
			echo "Session profile: ${DOTFILES_FEATURE_PROFILE:-full}"
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
	local canonical_repo_url="https://github.com/Msprg/dotFiles.git"
	local repo_dir workspace_dir clone_url target_branch bootstrap_script
	local use_temp_workspace='false'
	local temp_dir=''
	local persist_repo_dir='true'

	repo_dir="$(dotfiles_resolve_repo_dir 2> /dev/null || true)"

	if [ -n "$repo_dir" ]; then
		clone_url="$(git -C "$repo_dir" config --get remote.origin.url 2> /dev/null || true)"
		target_branch="$(__dotfiles_update_target_branch "$repo_dir" 2> /dev/null || printf '%s\n' 'main')"
	else
		clone_url="$canonical_repo_url"
		target_branch='main'
	fi
	[ -n "$clone_url" ] || clone_url="$canonical_repo_url"

	if [ -n "$repo_dir" ] && [ -w "$repo_dir" ] && [ -w "$repo_dir/.git" ]; then
		workspace_dir="$repo_dir"
	else
		use_temp_workspace='true'
		persist_repo_dir='false'
		temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-update.XXXXXX")" || {
			echo "dotfiles_update: could not create temp workspace" >&2
			return 1
		}
		workspace_dir="$temp_dir/dotFiles"

		echo "Using temporary workspace for update: $workspace_dir"
		if ! git clone --depth 1 --branch "$target_branch" "$clone_url" "$workspace_dir"; then
			rm -rf "$temp_dir"
			echo "dotfiles_update: clone failed from $clone_url (branch: $target_branch)" >&2
			return 1
		fi
	fi

	if [[ "$use_temp_workspace" != "true" ]]; then
		if [ -n "$(git -C "$workspace_dir" status --porcelain 2> /dev/null)" ]; then
			echo "dotfiles_update: local changes detected in $workspace_dir"
			echo "Commit or stash changes, then run dotfiles_update again."
			return 1
		fi
	fi

	bootstrap_script="$workspace_dir/bootstrap.sh"
	if [ ! -r "$bootstrap_script" ]; then
		[ -n "$temp_dir" ] && rm -rf "$temp_dir"
		echo "dotfiles_update: bootstrap script not found at $bootstrap_script" >&2
		return 1
	fi

	echo "Updating dotfiles from $workspace_dir ..."
	if ! DOTFILES_BOOTSTRAP_NO_SOURCE_PROFILE='true' \
		DOTFILES_BOOTSTRAP_PERSIST_REPO_DIR="$persist_repo_dir" \
		bash -c 'bootstrap_script="$1"; set -- -f; source "$bootstrap_script"' _ "$bootstrap_script"; then
		[ -n "$temp_dir" ] && rm -rf "$temp_dir"
		echo "dotfiles_update: bootstrap update failed" >&2
		return 1
	fi

	# Refresh update-check cache so the next shell prompt starts from fresh state.
	if [[ "$use_temp_workspace" == "true" ]]; then
		if declare -F __dotfiles_write_update_state > /dev/null; then
			local synced_commit
			synced_commit="$(git -C "$workspace_dir" rev-parse HEAD 2> /dev/null || true)"
			__dotfiles_write_update_state "up_to_date" "$synced_commit" "$synced_commit" "$(date +%s)" ""
		fi
	else
		__dotfiles_run_update_check_worker > /dev/null 2>&1 || true
	fi

	if [ -n "$temp_dir" ]; then
		rm -rf "$temp_dir"
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
