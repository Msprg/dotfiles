#!/usr/bin/env bash
# Prompt, timer, and prompt-hook orchestration.

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
	if [[ "${DOTFILES_FEATURE_TRACK_COMMAND_DURATION:-false}" != "true" ]]; then
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
fancyX='✗'
checkmark='✓'
__dotfiles_last_pwd="$PWD"
__dotfiles_prompt_last_exit_code=0
__dotfiles_loaded_env_file=''
__dotfiles_loaded_env_signature=''
__dotfiles_loaded_env_vars=()
__dotfiles_update_notice_shown='false'
__dotfiles_update_state_dir="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles"
__dotfiles_update_state_file="$__dotfiles_update_state_dir/update_state"
__dotfiles_update_check_lock_dir="$__dotfiles_update_state_dir/update_check.lock"

if [[ "${DOTFILES_FEATURE_TRACK_COMMAND_DURATION:-false}" == "true" ]]; then
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

			if [[ "${PS0:-}" == *"$ps0_timer_hook"* ]]; then
				PS0="${PS0//$ps0_timer_hook/}"
			fi

			if [[ "$use_ps0" == 'true' ]]; then
				PS0="${ps0_timer_hook}${PS0:-}"
				export PS0
				# Keep timing start in one place (PS0); the shared DEBUG
				# trap (10-history.bash) may still be installed for the
				# audit capture, so only disarm the timer side here.
				__dotfiles_debug_timer_armed=0
				trap - DEBUG
				dotfiles_dbg ".FUNCTIONS installed PS0 hook for timer_start (method=${requested_method})"
			else
				__dotfiles_debug_timer_armed=1
				__dotfiles_install_debug_trap
				dotfiles_dbg ".FUNCTIONS installed DEBUG trap for timer_start (method=debug)"
			fi
		else
			__dotfiles_debug_timer_armed=1
			__dotfiles_install_debug_trap
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
	if [[ "${DOTFILES_FEATURE_HISTORY_AUDIT:-true}" == "true" ]]; then
		append_bash_history_audit
	fi
	__dotfiles_maybe_show_update_notice_once

	if [[ "${DOTFILES_FEATURE_AUTO_DOT_ENV:-false}" == "true" ]]; then
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

		long_threshold_us="${DOTFILES_FEATURE_PROMPT_LONG_COMMAND_US:-750000}"
		divider_threshold_us="${DOTFILES_FEATURE_PROMPT_DIVIDER_THRESHOLD_US:-100000}"
		metadata_mode="${DOTFILES_FEATURE_PROMPT_METADATA_MODE:-never}"

		[[ "$long_threshold_us" =~ ^[0-9]+$ ]] || long_threshold_us=100000
		[[ "$divider_threshold_us" =~ ^[0-9]+$ ]] || divider_threshold_us=100000

		if (( _last_cmd_us > long_threshold_us )); then
			command_is_long='true'
		fi

		if [[ "${DOTFILES_FEATURE_PROMPT_METADATA:-false}" == "true" ]]; then
			case "$metadata_mode" in
				always)
					should_show_metadata='true'
					;;
				smart)
					if [[ "$command_is_long" == "true" ]]; then
						should_show_metadata='true'
					elif [[ "${DOTFILES_FEATURE_PROMPT_SHOW_ON_ERROR:-false}" == "true" && "$last_cmd_exit_code" -ne 0 ]]; then
						should_show_metadata='true'
					fi
					;;
			esac
		fi

		if [[ "$should_show_metadata" == "true" && "${DOTFILES_FEATURE_PROMPT_SHOW_EXIT_CODE:-false}" == "true" ]]; then
			printf -v combined_buff "%sexit: %-3d" "$combined_buff" "$last_cmd_exit_code"
		fi

		if [[ "$should_show_metadata" == "true" && "${DOTFILES_FEATURE_PROMPT_SHOW_STATUS_SYMBOL:-false}" == "true" ]]; then
			if [ -n "$combined_buff" ]; then
				combined_buff+=" "
			fi
			if [[ "$last_cmd_exit_code" == 0 ]]; then
				combined_buff+="${c_green}${checkmark}"
			else
				combined_buff+="${c_red}${fancyX}"
			fi
		fi

		if [[ "$should_show_metadata" == "true" && "${DOTFILES_FEATURE_PROMPT_SHOW_DURATION:-false}" == "true" ]]; then
			if [ -n "$combined_buff" ]; then
				combined_buff+="  "
			fi
			combined_buff+="${c_white}(${timer_show})"
		fi

		# Show the divider line after commands that likely produced substantial output.
		# Exact line counting is not feasible from bash (terminal scrolling makes
		# cursor-position deltas unreliable), so command duration is used as proxy.
		if [[ "${DOTFILES_FEATURE_PROMPT_SHOW_DIVIDER:-false}" == "true" ]] && (( _last_cmd_us > divider_threshold_us )); then
			should_show_divider='true'
		fi

		if [[ "$DOTFILES_DEBUG" == "true" && "${DOTFILES_DEBUG_PROMPT_VERBOSE:-false}" == "true" ]]; then
			printf '[DOTFILE_DBG: do_my_checks non-cd exit=%s duration_us=%s metadata=%s divider=%s mode=%s]\n' \
				"$last_cmd_exit_code" "$_last_cmd_us" "$should_show_metadata" "$should_show_divider" "$metadata_mode"
		fi

		# The custom prompt already starts with a newline, so avoid adding an
		# extra blank line between metadata/divider output and PS1 in that mode.
		if [[ "${DOTFILES_FEATURE_CUSTOM_PROMPT:-false}" == "true" ]]; then
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

	if [[ "${DOTFILES_FEATURE_LOCAL_HISTORY:-false}" == "true" ]]; then
		check_for_local_history
	elif [[ "$DOTFILES_DEBUG" == "true" && "${DOTFILES_DEBUG_PROMPT_VERBOSE:-false}" == "true" ]]; then
		dotfiles_dbg "do_my_checks skipped check_for_local_history (DOTFILES_FEATURE_LOCAL_HISTORY=false)"
	fi

#	check_for_nvmrc
#	check_for_ruby_version

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

		case "$prompt_part" in
			'' | do_my_checks | capture_prompt_exit_status | __dotfiles_audit_prompt_hook | __dotfiles_audit_capture_arm)
				continue
				;;
		esac

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

		case "$prompt_part" in
			'' | do_my_checks | capture_prompt_exit_status | __dotfiles_audit_prompt_hook | __dotfiles_audit_capture_arm)
				continue
				;;
		esac

		if [ -z "$rebuilt_prompt_command" ]; then
			rebuilt_prompt_command="$prompt_part"
		else
			rebuilt_prompt_command="${rebuilt_prompt_command};${prompt_part}"
		fi
	done

	PROMPT_COMMAND="$rebuilt_prompt_command"
	dotfiles_dbg ".FUNCTIONS removed do_my_checks from PROMPT_COMMAND -> '${PROMPT_COMMAND:-}'"
}

if [[ "${DOTFILES_FEATURE_PROMPT_HOOKS:-false}" == "true" ]]; then
	add_prompt_command
	if [[ "${DOTFILES_FEATURE_HISTORY_AUDIT:-true}" == "true" ]]; then
		__dotfiles_install_audit_capture
	fi
elif [[ "${DOTFILES_FEATURE_HISTORY_AUDIT:-true}" == "true" ]]; then
	# Minimal-style profile with auditing on: no cosmetics, but every prompt
	# cycle still records the last command (see 10-history.bash).
	remove_prompt_command
	__dotfiles_install_lean_audit_hook
else
	remove_prompt_command
fi
dotfiles_dbg ".FUNCTIONS prompt hook decision: DOTFILES_FEATURE_PROMPT_HOOKS=${DOTFILES_FEATURE_PROMPT_HOOKS:-unset}"
dotfiles_dbg ".FUNCTIONS feature summary: profile=${DOTFILES_FEATURE_PROFILE:-unset} custom_prompt=${DOTFILES_FEATURE_CUSTOM_PROMPT:-unset} metadata_mode=${DOTFILES_FEATURE_PROMPT_METADATA_MODE:-unset} track_duration=${DOTFILES_FEATURE_TRACK_COMMAND_DURATION:-unset} track_method=${DOTFILES_FEATURE_TRACK_COMMAND_DURATION_METHOD:-unset} local_history=${DOTFILES_FEATURE_LOCAL_HISTORY:-unset} auto_dot_env=${DOTFILES_FEATURE_AUTO_DOT_ENV:-unset} update_check=${DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK:-unset} update_scope=${DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK_SCOPE:-unset} update_interval_s=${DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK_INTERVAL_SECONDS:-unset}"

__dotfiles_maybe_show_update_notice_once
__dotfiles_schedule_update_check_async
