#!/usr/bin/env bash
# Internal dotfiles runtime functions (prompt hooks, history/env automation, shared helpers).

#!SECTION per-directory Bash history
function check_for_local_history {
	function main {
		if found_local_history_file; then
			if [ ! "$PWD" == "$HOME" ]; then
				echo "⌚ Using local Bash history"
			fi

			use_history_file "$PWD/.bash_history"
		else
			use_history_file ~/.bash_history
		fi
	}

	function found_local_history_file {
		[ -e .bash_history ]
  	}

	function use_history_file {
		history -w
		history -c
		export HISTFILE="$1"
		history -r
	}

	main
}

function audit_history_file_path {
	local base_histfile="${HISTFILE:-$HOME/.bash_history}"
	local audit_dir

	audit_dir="$(dirname "$base_histfile")"
	printf '%s/.bash_history_audit\n' "$audit_dir"
}

function ensure_audit_history_file {
	local audit_file
	local audit_dir
	local mkdir_rc touch_rc chmod_rc

	audit_file="$(audit_history_file_path)"
	audit_dir="$(dirname "$audit_file")"
	dotfiles_dbg ".FUNCTIONS audit ensure file: HISTFILE='${HISTFILE:-}' audit_file='$audit_file' audit_dir='$audit_dir'"

	mkdir -p "$audit_dir"
	mkdir_rc=$?
	if [ "$mkdir_rc" -ne 0 ]; then
		dotfiles_dbg ".FUNCTIONS audit ensure file failed: mkdir -p '$audit_dir' rc=$mkdir_rc"
		return 1
	fi
	if [ ! -e "$audit_file" ]; then
		dotfiles_dbg ".FUNCTIONS audit ensure file creating '$audit_file'"
		touch "$audit_file"
		touch_rc=$?
		if [ "$touch_rc" -ne 0 ]; then
			dotfiles_dbg ".FUNCTIONS audit ensure file failed: touch '$audit_file' rc=$touch_rc"
			return 1
		fi
		chmod 600 "$audit_file"
		chmod_rc=$?
		if [ "$chmod_rc" -ne 0 ]; then
			dotfiles_dbg ".FUNCTIONS audit ensure file failed: chmod 600 '$audit_file' rc=$chmod_rc"
			return 1
		fi
		dotfiles_dbg ".FUNCTIONS audit ensure file created '$audit_file' with mode 600"
	elif [ ! -w "$audit_file" ]; then
		dotfiles_dbg ".FUNCTIONS audit ensure file warning: '$audit_file' exists but is not writable"
	fi

	dotfiles_dbg ".FUNCTIONS audit ensure file ready: '$audit_file'"
}

function last_history_command_for_audit {
	local command_raw
	local command_escaped

	# `fc -ln -1` prefixes entries with one leading whitespace character.
	command_raw="$(builtin fc -ln -1 | sed 's/^[[:space:]]//')"
	if [ -z "$command_raw" ]; then
		dotfiles_dbg ".FUNCTIONS audit command read skipped: empty command from fc -ln -1" >&2
		return 1
	fi

	# Keep single-line commands human-readable; only escape multiline entries
	# to keep the TSV audit log one-record-per-line.
	if [[ "$command_raw" == *$'\n'* ]]; then
		printf -v command_escaped '%q' "$command_raw"
		dotfiles_dbg ".FUNCTIONS audit command read multiline: raw_len=${#command_raw} escaped_len=${#command_escaped}" >&2
		printf '%s\n' "$command_escaped"
		return
	fi

	dotfiles_dbg ".FUNCTIONS audit command read single-line: len=${#command_raw}" >&2
	printf '%s\n' "$command_raw"
}

function last_history_event_id_for_audit {
	local history_line

	history_line="$(builtin history 1)"
	if [[ "$history_line" =~ ^[[:space:]]*([0-9]+)[[:space:]] ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi

	dotfiles_dbg ".FUNCTIONS audit event read skipped: could not parse history event from history 1" >&2
	return 1
}

function parse_audit_line_for_dedupe {
	local audit_line="$1"

	# Expected format:
	# <timestamp>  <user>  exit:<code>  took:<duration>  <command>
	if [[ "$audit_line" =~ ^([^[:space:]]+)[[:space:]]{2,}([^[:space:]]+)[[:space:]]{2,}exit:[[:space:]]*([-0-9]+)[[:space:]]{2,}took:[^[:space:]]+[[:space:]]{2,}(.*)$ ]]; then
		printf '%s\t%s\t%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
		return 0
	fi

	return 1
}

function replace_last_line_in_file {
	local target_file="$1"
	local replacement_line="$2"
	local target_dir temp_file

	target_dir="$(dirname "$target_file")"
	temp_file="$(mktemp "$target_dir/.bash_history_audit.tmp.XXXXXX")" || return 1

	if [ -s "$target_file" ]; then
		sed '$d' "$target_file" > "$temp_file" || {
			rm -f "$temp_file"
			return 1
		}
	fi

	printf '%s\n' "$replacement_line" >> "$temp_file" || {
		rm -f "$temp_file"
		return 1
	}

	mv "$temp_file" "$target_file" || {
		rm -f "$temp_file"
		return 1
	}
}

function append_bash_history_audit {
	local audit_file timestamp history_user command_for_audit
	local cmd_exit duration_us duration_display
	local command_read_rc ensure_rc write_rc
	local history_event history_key current_histfile
	local audit_file_writable='false'
	local audit_dir_writable='false'
	local audit_line lock_file lock_fd lock_rc
	local last_audit_line last_audit_user last_audit_exit last_audit_command parsed_last_line
	local should_replace='false'

	history_event="$(last_history_event_id_for_audit)" || return 0
	current_histfile="${HISTFILE:-$HOME/.bash_history}"
	history_key="${current_histfile}:${history_event}"
	if [ "$history_key" = "${__dotfiles_last_audit_history_key:-}" ]; then
		dotfiles_dbg ".FUNCTIONS audit append skipped: history event '$history_key' already audited"
		return 0
	fi

	dotfiles_dbg ".FUNCTIONS audit append start: history_event='$history_event' history_key='$history_key' last_audited='${__dotfiles_last_audit_history_key:-}' HISTFILE='$current_histfile'"
	command_for_audit="$(last_history_command_for_audit)"
	command_read_rc=$?
	if [ "$command_read_rc" -ne 0 ]; then
		dotfiles_dbg ".FUNCTIONS audit append skipped: command read failed rc=$command_read_rc"
		return 0
	fi
	dotfiles_dbg ".FUNCTIONS audit append command ready: len=${#command_for_audit}"

	ensure_audit_history_file
	ensure_rc=$?
	if [ "$ensure_rc" -ne 0 ]; then
		dotfiles_dbg ".FUNCTIONS audit append skipped: ensure_audit_history_file failed rc=$ensure_rc"
		return 0
	fi
	audit_file="$(audit_history_file_path)"
	if [ -w "$audit_file" ]; then
		audit_file_writable='true'
	fi
	if [ -w "$(dirname "$audit_file")" ]; then
		audit_dir_writable='true'
	fi

	timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
	history_user="${BASH_HISTORY_USERNAME:-${USER:-unknown}}"
	cmd_exit="${last_cmd_exit_code:-0}"
	duration_us="${_last_cmd_us:-0}"
	duration_display="$(format_duration_us "$duration_us")"
	dotfiles_dbg ".FUNCTIONS audit append write attempt: file='$audit_file' file_writable=$audit_file_writable dir_writable=$audit_dir_writable exit=$cmd_exit duration_us=$duration_us duration='$duration_display'"

	printf -v audit_line '%-24s  %-24s  exit:%-3s  took:%-9s  %s' \
		"$timestamp" "$history_user" "$cmd_exit" "$duration_display" "$command_for_audit"

	lock_file="${audit_file}.lock"
	lock_fd=''
	if command -v flock > /dev/null 2>&1; then
		exec {lock_fd}>>"$lock_file"
		lock_rc=$?
		if [ "$lock_rc" -ne 0 ]; then
			dotfiles_dbg ".FUNCTIONS audit append lock open failed: lock='$lock_file' rc=$lock_rc"
			return 0
		fi
		flock -x "$lock_fd"
		lock_rc=$?
		if [ "$lock_rc" -ne 0 ]; then
			dotfiles_dbg ".FUNCTIONS audit append lock acquire failed: lock='$lock_file' rc=$lock_rc"
			exec {lock_fd}>&-
			return 0
		fi
	fi

	if [ -s "$audit_file" ]; then
		last_audit_line="$(tail -n 1 "$audit_file")"
		parsed_last_line="$(parse_audit_line_for_dedupe "$last_audit_line")"
		if [ $? -eq 0 ]; then
			IFS=$'\t' read -r last_audit_user last_audit_exit last_audit_command <<< "$parsed_last_line"
			if [ "$last_audit_user" = "$history_user" ] \
				&& [ "$last_audit_exit" = "$cmd_exit" ] \
				&& [ "$last_audit_command" = "$command_for_audit" ]; then
				should_replace='true'
			fi
		fi
	fi

	if [ "$should_replace" = 'true' ]; then
		replace_last_line_in_file "$audit_file" "$audit_line"
		write_rc=$?
		if [ "$write_rc" -eq 0 ]; then
			dotfiles_dbg ".FUNCTIONS audit append replaced last entry: user='$history_user' exit=$cmd_exit"
		fi
	else
		printf '%s\n' "$audit_line" >> "$audit_file"
		write_rc=$?
		if [ "$write_rc" -eq 0 ]; then
			dotfiles_dbg ".FUNCTIONS audit append appended new entry: user='$history_user' exit=$cmd_exit"
		fi
	fi

	if [ -n "$lock_fd" ]; then
		flock -u "$lock_fd" > /dev/null 2>&1 || true
		exec {lock_fd}>&-
	fi

	if [ "${write_rc:-1}" -eq 0 ]; then
		__dotfiles_last_audit_history_key="$history_key"
		dotfiles_dbg ".FUNCTIONS audit append success: history_event='$history_event' recorded in '$audit_file'"
	else
		dotfiles_dbg ".FUNCTIONS audit append failed: rc=${write_rc:-1} file='$audit_file' file_writable=$audit_file_writable dir_writable=$audit_dir_writable"
	fi
}


function changing_directory {
	# Compare current directory with the previously seen one.
	# This avoids history parsing and alias scans on every prompt while still
	# catching `cd`, aliases, `pushd/popd`, and any other PWD-changing command.
	if [[ "$PWD" != "${__dotfiles_last_pwd:-$PWD}" ]]; then
		__dotfiles_last_pwd="$PWD"
		return 0
	fi
	return 1
}

#function check_for_nvmrc {
#	local nvm_node_path="$HOME/.nvm/versions/node"
#
#	function main {
#		if [ -e .nvmrc ]; then
#			local expected_node_version=`get_version_from_nvmrc`
#			local expected_node_path="$nvm_node_path/$expected_node_version/bin"
#			local current_node_version=`get_current_node_version`
#
#			if [[ -n $current_node_version && $current_node_version =~ $expected_node_version ]]; then
#				return
#			fi
#
#			if [ -d $expected_node_path ]; then
#				# Remove previous nvm_node_path from PATH if found
#				export PATH=$expected_node_path:`remove_path_item_matching $nvm_node_path`
#				echo "Changed Node version to $(node -v)"
#			else
#				export NVM_DIR="$HOME/.nvm"
#				source "$NVM_DIR/nvm.sh"  # This loads nvm
#				nvm use
#			fi
#		fi
#	}
#
#	function get_current_node_version {
#		if [[ "$(type -t nvm)" == "function" ]]; then
#			nvm current
#			return
#		fi
#
#		if [[ "$(type -t node)" == "file" ]]; then
#			node --version
#			return
#		fi
#	}
#
#	function get_version_from_nvmrc {
#		local version=$(<.nvmrc)
#		version=${version/v/}
#		echo v$version
#	}
#
#	function remove_path_item_matching {
#		local path_item=$1
#
#		if grep -F "$path_item" <<<$PATH ; then
#			escaped_path_item=${path_item//\//\\/} # escape slashes for the awk regexp
#			awk -v RS=: -v ORS=: "/$escaped_path_item/ {next} {print}" <<<$PATH
#		else
#			echo $PATH
#		fi
#	}
#
#	main
#}

#function check_for_ruby_version {
#	if [ -e .ruby-version ]; then
#		source "$HOME/.rvm/scripts/rvm" # Load RVM into a shell session *as a function*
#		rvm use
#	fi
#}

function unload_dot_env_vars {
	if [ "${#__dotfiles_loaded_env_vars[@]}" -gt 0 ]; then
		unset "${__dotfiles_loaded_env_vars[@]}"
	fi
	__dotfiles_loaded_env_vars=()
}

function get_dot_env_signature {
	local env_file="$1"
	local checksum size remainder

	[ -f "$env_file" ] || return 1
	read -r checksum size remainder < <(cksum < "$env_file")
	printf '%s:%s\n' "$checksum" "$size"
}

function check_for_dot_env {
	local current_env_file="$PWD/.env"
	local env_signature source_status=0
	local env_vars=()
	local line

	if [ ! -f "$current_env_file" ]; then
		if [ -n "${__dotfiles_loaded_env_file:-}" ]; then
			unload_dot_env_vars
			__dotfiles_loaded_env_file=''
			__dotfiles_loaded_env_signature=''
		fi
		return 0
	fi

	env_signature="$(get_dot_env_signature "$current_env_file")" || return 1
	if [[ "${__dotfiles_loaded_env_file:-}" == "$current_env_file" && "${__dotfiles_loaded_env_signature:-}" == "$env_signature" ]]; then
		return 0
	fi

	if [ -n "${__dotfiles_loaded_env_file:-}" ]; then
		unload_dot_env_vars
	fi
	__dotfiles_loaded_env_file=''
	__dotfiles_loaded_env_signature=''

	while IFS= read -r line || [ -n "$line" ]; do
		if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]]; then
			env_vars+=("${BASH_REMATCH[2]}")
		fi
	done < "$current_env_file"

	set -o allexport
	source "$current_env_file" || source_status=$?
	set +o allexport
	if [ "$source_status" -ne 0 ]; then
		return "$source_status"
	fi

	__dotfiles_loaded_env_vars=("${env_vars[@]}")
	__dotfiles_loaded_env_file="$current_env_file"
	__dotfiles_loaded_env_signature="$env_signature"
	echo "Loaded .env"
}

function dotfiles_resolve_repo_dir {
	local marker_file="${HOME}/.dotfiles_repo_dir"
	local candidate=''

	if [ -n "${DOTFILES_REPO_DIR:-}" ] \
		&& [ -d "$DOTFILES_REPO_DIR" ] \
		&& git -C "$DOTFILES_REPO_DIR" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
		printf '%s\n' "$DOTFILES_REPO_DIR"
		return 0
	fi

	if [ -r "$marker_file" ] && [ -f "$marker_file" ]; then
		IFS= read -r candidate < "$marker_file"
		if [ -n "$candidate" ] \
			&& [ -d "$candidate" ] \
			&& git -C "$candidate" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
			printf '%s\n' "$candidate"
			return 0
		fi
	fi

	for candidate in "$HOME/dotFiles" "$HOME/dotfiles"; do
		if [ -d "$candidate" ] \
			&& git -C "$candidate" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done

	return 1
}

function __dotfiles_update_target_branch {
	local repo_dir="$1"
	local origin_head_ref=''
	local branch='main'

	origin_head_ref="$(git -C "$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2> /dev/null || true)"
	if [[ -n "$origin_head_ref" && "$origin_head_ref" == origin/* ]]; then
		branch="${origin_head_ref#origin/}"
	fi

	printf '%s\n' "$branch"
}

function __dotfiles_read_update_state {
	local state_file="${__dotfiles_update_state_file:-${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/update_state}"
	local line key value

	__dotfiles_update_state_status=''
	__dotfiles_update_state_local_commit=''
	__dotfiles_update_state_remote_commit=''
	__dotfiles_update_state_last_check_epoch='0'
	__dotfiles_update_state_error=''

	[ -r "$state_file" ] && [ -f "$state_file" ] || return 0

	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			*=*)
				key="${line%%=*}"
				value="${line#*=}"
				;;
			*)
				continue
				;;
		esac

		case "$key" in
			status) __dotfiles_update_state_status="$value" ;;
			local_commit) __dotfiles_update_state_local_commit="$value" ;;
			remote_commit) __dotfiles_update_state_remote_commit="$value" ;;
			last_check_epoch) __dotfiles_update_state_last_check_epoch="$value" ;;
			error) __dotfiles_update_state_error="$value" ;;
		esac
	done < "$state_file"
}

function __dotfiles_write_update_state {
	local status="$1"
	local local_commit="$2"
	local remote_commit="$3"
	local last_check_epoch="$4"
	local error_message="$5"
	local state_dir="${__dotfiles_update_state_dir:-${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles}"
	local state_file="${__dotfiles_update_state_file:-$state_dir/update_state}"
	local tmp_state_file=''

	mkdir -p "$state_dir" || return 1
	tmp_state_file="$(mktemp "$state_dir/update_state.tmp.XXXXXX")" || return 1

	error_message="${error_message//$'\n'/ }"
	{
		printf 'status=%s\n' "$status"
		printf 'local_commit=%s\n' "$local_commit"
		printf 'remote_commit=%s\n' "$remote_commit"
		printf 'last_check_epoch=%s\n' "$last_check_epoch"
		printf 'error=%s\n' "$error_message"
	} > "$tmp_state_file" || {
		rm -f "$tmp_state_file"
		return 1
	}

	mv "$tmp_state_file" "$state_file" || {
		rm -f "$tmp_state_file"
		return 1
	}
}

function __dotfiles_should_auto_check_updates {
	local scope="${DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK_SCOPE:-interactive}"

	[[ $- == *i* ]] || return 1
	[[ "${DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK:-true}" == "true" ]] || return 1

	case "$scope" in
		ssh)
			[ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ]
			return $?
			;;
		interactive)
			return 0
			;;
		*)
			return 0
			;;
	esac
}

function __dotfiles_should_run_update_check_now {
	local interval_s="${DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK_INTERVAL_SECONDS:-43200}"
	local last_check_epoch now_epoch elapsed_s

	[[ "$interval_s" =~ ^[0-9]+$ ]] || interval_s=43200
	[ "$interval_s" -gt 0 ] || interval_s=43200

	__dotfiles_read_update_state
	last_check_epoch="${__dotfiles_update_state_last_check_epoch:-0}"
	[[ "$last_check_epoch" =~ ^[0-9]+$ ]] || last_check_epoch=0

	now_epoch="$(date +%s)"
	elapsed_s=$((now_epoch - last_check_epoch))
	[ "$elapsed_s" -ge "$interval_s" ]
}

function __dotfiles_run_update_check_worker {
	local state_dir="${__dotfiles_update_state_dir:-${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles}"
	local lock_dir="${__dotfiles_update_check_lock_dir:-$state_dir/update_check.lock}"
	local repo_dir branch local_commit remote_commit remote_url now_epoch
	local status error_message

	now_epoch="$(date +%s)"
	mkdir -p "$state_dir" || return 0
	if ! mkdir "$lock_dir" 2> /dev/null; then
		return 0
	fi

	repo_dir="$(dotfiles_resolve_repo_dir 2> /dev/null || true)"
	if [ -z "$repo_dir" ]; then
		__dotfiles_write_update_state "error" "" "" "$now_epoch" "Could not resolve dotfiles repo directory."
		rmdir "$lock_dir" 2> /dev/null
		return 0
	fi

	local_commit="$(git -C "$repo_dir" rev-parse HEAD 2> /dev/null || true)"
	branch="$(__dotfiles_update_target_branch "$repo_dir")"
	remote_url="$(git -C "$repo_dir" config --get remote.origin.url 2> /dev/null || true)"
	if [ -z "$remote_url" ]; then
		remote_url='origin'
	fi
	remote_commit="$(git -C "$repo_dir" ls-remote --heads "$remote_url" "refs/heads/$branch" 2> /dev/null | awk 'NR==1 {print $1}')"

	if [ -z "$local_commit" ] || [ -z "$remote_commit" ]; then
		error_message="Unable to read local/remote commit."
		__dotfiles_write_update_state "error" "$local_commit" "$remote_commit" "$now_epoch" "$error_message"
		rmdir "$lock_dir" 2> /dev/null
		return 0
	fi

	status='update_available'
	if [ "$local_commit" = "$remote_commit" ]; then
		status='up_to_date'
	fi

	__dotfiles_write_update_state "$status" "$local_commit" "$remote_commit" "$now_epoch" ""
	rmdir "$lock_dir" 2> /dev/null
}

function __dotfiles_schedule_update_check_async {
	local bg_pid

	__dotfiles_should_auto_check_updates || return 0
	__dotfiles_should_run_update_check_now || return 0

	( __dotfiles_run_update_check_worker > /dev/null 2>&1 ) &
	bg_pid=$!
	disown "$bg_pid" 2> /dev/null || true
}

function __dotfiles_maybe_show_update_notice_once {
	local local_short remote_short

	if [[ "${__dotfiles_update_notice_shown:-false}" == "true" ]]; then
		return 0
	fi
	__dotfiles_should_auto_check_updates || return 0
	__dotfiles_read_update_state

	if [ "${__dotfiles_update_state_status:-}" != "update_available" ]; then
		return 0
	fi

	local_short="${__dotfiles_update_state_local_commit:-unknown}"
	remote_short="${__dotfiles_update_state_remote_commit:-unknown}"
	local_short="${local_short:0:7}"
	remote_short="${remote_short:0:7}"

	printf 'Dotfiles update available: %s -> %s. Run: dotfiles_update\n' "$local_short" "$remote_short"
	__dotfiles_update_notice_shown='true'
}

# https://stackoverflow.com/a/34812608
function timer_now { date +%s%N; }

function timer_start { timer_start=${timer_start:-$(timer_now)}; }

function format_duration_us {
	local delta_us="${1:-0}"
	local us ms s m h duration_display

	if ! [[ "$delta_us" =~ ^[0-9]+$ ]]; then
		delta_us=0
	fi

	us=$((delta_us % 1000))
	ms=$(((delta_us / 1000) % 1000))
	s=$(((delta_us / 1000000) % 60))
	m=$(((delta_us / 60000000) % 60))
	h=$((delta_us / 3600000000))

	# Goal: always show around 3 digits of accuracy.
	if ((h > 0)); then
		duration_display=${h}h${m}m
	elif ((m > 0)); then
		duration_display=${m}m${s}s
	elif ((s >= 10)); then
		duration_display=${s}.$((ms / 100))s
	elif ((s > 0)); then
		duration_display=${s}.$(printf %03d "$ms")s
	elif ((ms >= 100)); then
		duration_display=${ms}ms
	elif ((ms > 0)); then
		duration_display=${ms}.$((us / 100))ms
	else
		duration_display=${us}us
	fi

	printf '%s\n' "$duration_display"
}

function timer_stop {
	if [[ "${DOTFILES_FEATURE_TRACK_COMMAND_DURATION:-true}" != "true" ]]; then
		_last_cmd_us=0
		timer_show='0us'
		unset timer_start
		return 0
	fi

	if [ -z "${timer_start:-}" ]; then
		_last_cmd_us=0
		timer_show='0us'
		return 0
	fi

	local delta_us=$((($(timer_now) - timer_start) / 1000))
	_last_cmd_us=$delta_us # raw microseconds, used by do_my_checks
	timer_show="$(format_duration_us "$delta_us")"

	unset timer_start
}

last_cmd_exit_code=$? # Here to init this env var on the dotfiles load
# export last_cmd_exit_code
fancyX='✗'
checkmark='✓'
__dotfiles_last_pwd="$PWD"
__dotfiles_last_audit_history_key=''
__dotfiles_prompt_last_exit_code=0
__dotfiles_loaded_env_file=''
__dotfiles_loaded_env_signature=''
__dotfiles_loaded_env_vars=()
__dotfiles_update_notice_shown='false'
__dotfiles_update_state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles"
__dotfiles_update_state_file="$__dotfiles_update_state_dir/update_state"
__dotfiles_update_check_lock_dir="$__dotfiles_update_state_dir/update_check.lock"

if [[ "${DOTFILES_FEATURE_TRACK_COMMAND_DURATION:-true}" == "true" ]]; then
	function __dotfiles_supports_ps0 {
		(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) ))
	}

	function __dotfiles_install_timer_start_hook {
		local requested_method="${DOTFILES_FEATURE_TRACK_COMMAND_DURATION_METHOD:-auto}"

		if __dotfiles_supports_ps0; then
			# `$(...)` in PS0 runs in a subshell, so state changes are lost.
			# Use parameter expansion assignment instead; the clear sequences
			# avoid showing the assigned timestamp in the terminal.
			local ps0_timer_marker='${timer_start:=$(timer_now)}'
			local ps0_timer_hook=$'\r\033[2K'"${ps0_timer_marker}"$'\r\033[2K'
			local legacy_ps0_hook='$(__dotfiles_timer_start_ps0)'
			local use_ps0='false'

			case "$requested_method" in
				ps0) use_ps0='true' ;;
				auto) use_ps0='true' ;;
				debug) use_ps0='false' ;;
				*)
					dotfiles_dbg ".FUNCTIONS unknown DOTFILES_FEATURE_TRACK_COMMAND_DURATION_METHOD='${requested_method}'; using auto"
					use_ps0='true'
					;;
			esac

			if [[ "${PS0:-}" == *"$legacy_ps0_hook"* ]]; then
				PS0="${PS0//$legacy_ps0_hook/}"
			fi
			if [[ "${PS0:-}" == *"$ps0_timer_hook"* ]]; then
				PS0="${PS0//$ps0_timer_hook/}"
			fi

			if [[ "$use_ps0" == 'true' ]]; then
				PS0="${ps0_timer_hook}${PS0:-}"
				export PS0
				# Keep timing start in one place (PS0) to avoid DEBUG-trap overhead.
				trap - DEBUG
				dotfiles_dbg ".FUNCTIONS installed PS0 hook for timer_start (method=${requested_method})"
			else
				trap 'timer_start' DEBUG
				dotfiles_dbg ".FUNCTIONS installed DEBUG trap for timer_start (method=debug)"
			fi
		else
			trap 'timer_start' DEBUG
			dotfiles_dbg ".FUNCTIONS installed DEBUG trap for timer_start (PS0 unsupported, method=${requested_method})"
		fi
	}

	__dotfiles_install_timer_start_hook
else
	dotfiles_dbg ".FUNCTIONS skipped timer_start hook; DOTFILES_FEATURE_TRACK_COMMAND_DURATION=false"
fi

function do_my_checks {
	last_cmd_exit_code="${__dotfiles_prompt_last_exit_code:-$?}"
	timer_stop # call asap after acquiring the last exit code
	append_bash_history_audit
	__dotfiles_maybe_show_update_notice_once

	if [[ "${DOTFILES_FEATURE_AUTO_DOT_ENV:-true}" == "true" ]]; then
		check_for_dot_env
	fi

	if ! changing_directory; then
		local long_threshold_us divider_threshold_us metadata_mode
		local should_show_metadata='false'
		local should_show_divider='false'
		local prompt_already_adds_newline='false'
		local command_is_long='false'
		local combined_buff=''
		local freecols divider

		local c_green="${green:-$'\033[1;32m'}"
		local c_red="${red:-$'\033[1;31m'}"
		local c_white="${white:-$'\033[1;37m'}"
		local c_brightred="${brightred:-$'\033[38;5;196m'}"
		local c_reset="${reset:-$'\033[0m'}"

		long_threshold_us="${DOTFILES_FEATURE_PROMPT_LONG_COMMAND_US:-100000}"
		divider_threshold_us="${DOTFILES_FEATURE_PROMPT_DIVIDER_THRESHOLD_US:-100000}"
		metadata_mode="${DOTFILES_FEATURE_PROMPT_METADATA_MODE:-always}"

		[[ "$long_threshold_us" =~ ^[0-9]+$ ]] || long_threshold_us=100000
		[[ "$divider_threshold_us" =~ ^[0-9]+$ ]] || divider_threshold_us=100000

		if (( _last_cmd_us > long_threshold_us )); then
			command_is_long='true'
		fi

		if [[ "${DOTFILES_FEATURE_PROMPT_METADATA:-true}" == "true" ]]; then
			case "$metadata_mode" in
				always)
					should_show_metadata='true'
					;;
				smart)
					if [[ "$command_is_long" == "true" ]]; then
						should_show_metadata='true'
					elif [[ "${DOTFILES_FEATURE_PROMPT_SHOW_ON_ERROR:-true}" == "true" && "$last_cmd_exit_code" -ne 0 ]]; then
						should_show_metadata='true'
					fi
					;;
			esac
		fi

		if [[ "$should_show_metadata" == "true" && "${DOTFILES_FEATURE_PROMPT_SHOW_EXIT_CODE:-true}" == "true" ]]; then
			printf -v combined_buff "%sexit: %-3d" "$combined_buff" "$last_cmd_exit_code"
		fi

		if [[ "$should_show_metadata" == "true" && "${DOTFILES_FEATURE_PROMPT_SHOW_STATUS_SYMBOL:-true}" == "true" ]]; then
			if [ -n "$combined_buff" ]; then
				combined_buff+=" "
			fi
			if [[ "$last_cmd_exit_code" == 0 ]]; then
				combined_buff+="${c_green}${checkmark}"
			else
				combined_buff+="${c_red}${fancyX}"
			fi
		fi

		if [[ "$should_show_metadata" == "true" && "${DOTFILES_FEATURE_PROMPT_SHOW_DURATION:-true}" == "true" ]]; then
			if [ -n "$combined_buff" ]; then
				combined_buff+="  "
			fi
			combined_buff+="${c_white}(${timer_show})"
		fi

		# Show the divider line after commands that likely produced substantial output.
		# Exact line counting is not feasible from bash (terminal scrolling makes
		# cursor-position deltas unreliable), so command duration is used as proxy.
		if [[ "${DOTFILES_FEATURE_PROMPT_SHOW_DIVIDER:-true}" == "true" ]] && (( _last_cmd_us > divider_threshold_us )); then
			should_show_divider='true'
		fi

		if [[ "$DOTFILES_DEBUG" == "true" && "${DOTFILES_DEBUG_PROMPT_VERBOSE:-false}" == "true" ]]; then
			printf '[DOTFILE_DBG: do_my_checks non-cd exit=%s duration_us=%s metadata=%s divider=%s mode=%s]\n' \
				"$last_cmd_exit_code" "$_last_cmd_us" "$should_show_metadata" "$should_show_divider" "$metadata_mode"
		fi

		# The custom prompt already starts with a newline, so avoid adding an
		# extra blank line between metadata/divider output and PS1 in that mode.
		if [[ "${DOTFILES_FEATURE_CUSTOM_PROMPT:-true}" == "true" ]]; then
			prompt_already_adds_newline='true'
		fi

		if [ -n "$combined_buff" ] || [[ "$should_show_divider" == "true" ]]; then
			printf "\n" # separate command output from metadata/prompt
		fi


		if [ -n "$combined_buff" ]; then
			printf "%s" "$combined_buff"
		fi

		if [[ "$should_show_divider" == "true" ]]; then
			divider_spacer="      " # add divider spacer / preamble
			freecols=$((${COLUMNS:-80} - ${#combined_buff} - ${#divider_spacer}))
			(( freecols < 1 )) && freecols=1
			# echo -n "cb:${#combined_buff}"
			# echo -n "fc:$freecols"
			divider="$(printf '%*s' "$freecols" '' | tr ' ' '-')"
			printf "%s%s%s%s" "$c_brightred" "$divider_spacer" "$divider" "$c_reset"

		elif [ -n "$combined_buff" ]; then
			printf "%s" "$c_reset"
		fi

		if { [ -n "$combined_buff" ] || [[ "$should_show_divider" == "true" ]]; } && [[ "$prompt_already_adds_newline" != "true" ]]; then
			printf "\n" # separate command output from metadata/prompt
		fi

		return
	fi

	if [[ "${DOTFILES_FEATURE_LOCAL_HISTORY:-true}" == "true" ]]; then
		check_for_local_history
	elif [[ "$DOTFILES_DEBUG" == "true" && "${DOTFILES_DEBUG_PROMPT_VERBOSE:-false}" == "true" ]]; then
		dotfiles_dbg "do_my_checks skipped check_for_local_history (DOTFILES_FEATURE_LOCAL_HISTORY=false)"
	fi

#	check_for_nvmrc
#	check_for_ruby_version

#	set_macos_terminal_tab_title
}

function set_macos_terminal_tab_title {
	local home_relative_path=$(realpath --relative-to="$HOME" "$PWD")

	echo -n -e "\033]0;~/${home_relative_path}\007"
}

function capture_prompt_exit_status {
	__dotfiles_prompt_last_exit_code=$?
}

function add_prompt_command {
	local current_prompt_command="${PROMPT_COMMAND:-}"
	local rebuilt_prompt_command=''
	local prompt_part
	local prompt_parts=()
	local normalized_prompt_command

	IFS=';' read -r -a prompt_parts <<< "$current_prompt_command"
	for prompt_part in "${prompt_parts[@]}"; do
		prompt_part="${prompt_part#"${prompt_part%%[![:space:]]*}"}"
		prompt_part="${prompt_part%"${prompt_part##*[![:space:]]}"}"

		if [ -z "$prompt_part" ] || [ "$prompt_part" = 'do_my_checks' ] || [ "$prompt_part" = 'capture_prompt_exit_status' ]; then
			continue
		fi

		if [ -z "$rebuilt_prompt_command" ]; then
			rebuilt_prompt_command="$prompt_part"
		else
			rebuilt_prompt_command="${rebuilt_prompt_command};${prompt_part}"
		fi
	done

	if [ -n "$rebuilt_prompt_command" ]; then
		normalized_prompt_command="capture_prompt_exit_status;${rebuilt_prompt_command};do_my_checks"
	else
		normalized_prompt_command='capture_prompt_exit_status;do_my_checks'
	fi

	PROMPT_COMMAND="$normalized_prompt_command"
	dotfiles_dbg ".FUNCTIONS normalized PROMPT_COMMAND -> '$PROMPT_COMMAND'"
}

function remove_prompt_command {
	local current_prompt_command="${PROMPT_COMMAND:-}"
	local rebuilt_prompt_command=''
	local prompt_part
	local prompt_parts=()

	IFS=';' read -r -a prompt_parts <<< "$current_prompt_command"
	for prompt_part in "${prompt_parts[@]}"; do
		prompt_part="${prompt_part#"${prompt_part%%[![:space:]]*}"}"
		prompt_part="${prompt_part%"${prompt_part##*[![:space:]]}"}"

		if [ -z "$prompt_part" ] || [ "$prompt_part" = 'do_my_checks' ] || [ "$prompt_part" = 'capture_prompt_exit_status' ]; then
			continue
		fi

		if [ -z "$rebuilt_prompt_command" ]; then
			rebuilt_prompt_command="$prompt_part"
		else
			rebuilt_prompt_command="${rebuilt_prompt_command};${prompt_part}"
		fi
	done

	PROMPT_COMMAND="$rebuilt_prompt_command"
	dotfiles_dbg ".FUNCTIONS removed do_my_checks from PROMPT_COMMAND -> '${PROMPT_COMMAND:-}'"
}

if [[ "${DOTFILES_FEATURE_PROMPT_HOOKS:-true}" == "true" ]]; then
	add_prompt_command
else
	remove_prompt_command
fi
dotfiles_dbg ".FUNCTIONS prompt hook decision: DOTFILES_FEATURE_PROMPT_HOOKS=${DOTFILES_FEATURE_PROMPT_HOOKS:-unset}"
dotfiles_dbg ".FUNCTIONS feature summary: profile=${DOTFILES_FEATURE_PROFILE:-unset} custom_prompt=${DOTFILES_FEATURE_CUSTOM_PROMPT:-unset} metadata_mode=${DOTFILES_FEATURE_PROMPT_METADATA_MODE:-unset} track_duration=${DOTFILES_FEATURE_TRACK_COMMAND_DURATION:-unset} track_method=${DOTFILES_FEATURE_TRACK_COMMAND_DURATION_METHOD:-unset} local_history=${DOTFILES_FEATURE_LOCAL_HISTORY:-unset} auto_dot_env=${DOTFILES_FEATURE_AUTO_DOT_ENV:-unset} update_check=${DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK:-unset} update_scope=${DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK_SCOPE:-unset} update_interval_s=${DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK_INTERVAL_SECONDS:-unset}"

__dotfiles_maybe_show_update_notice_once
__dotfiles_schedule_update_check_async


function _dotfiles_unset_runtime_env {
	local var_name

	while IFS= read -r var_name; do
		unset "$var_name"
	done < <(compgen -v | grep -E '^DOTFILES_FEATURE_')

	unset var_name
	unset PS0 PS1 PS2 PS4 PROMPT_COMMAND
}

function _command_exists() {
#	_about 'checks for existence of a command'
#	_param '1: command to check'
#	_param '2: (optional) log message to include when command not found'
#	_example '$ _command_exists ls && echo exists'
#	_group 'lib'
	local msg="${2:-Command '$1' does not exist}"
	if type -t "$1" > /dev/null; then
		return 0
	else
		#_log_debug "$msg"
		return 1
	fi
}
