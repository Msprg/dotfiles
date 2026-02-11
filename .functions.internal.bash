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

	audit_file="$(audit_history_file_path)"
	audit_dir="$(dirname "$audit_file")"

	mkdir -p "$audit_dir" || return 1
	if [ ! -e "$audit_file" ]; then
		touch "$audit_file" || return 1
		chmod 600 "$audit_file" || return 1
	fi
}

function last_history_command_for_audit {
	local command_raw
	local command_escaped

	# `fc -ln -1` prefixes entries with one leading whitespace character.
	command_raw="$(builtin fc -ln -1 | sed 's/^[[:space:]]//')"
	[ -z "$command_raw" ] && return 1

	# Keep single-line commands human-readable; only escape multiline entries
	# to keep the TSV audit log one-record-per-line.
	if [[ "$command_raw" == *$'\n'* ]]; then
		printf -v command_escaped '%q' "$command_raw"
		printf '%s\n' "$command_escaped"
		return
	fi

	printf '%s\n' "$command_raw"
}

function append_bash_history_audit {
	local current_histcmd="${HISTCMD:-}"
	local audit_file timestamp history_user history_user_display command_for_audit
	local cmd_exit duration_us duration_display

	[ -z "$current_histcmd" ] && return 0
	if [ "$current_histcmd" = "${__dotfiles_last_audit_histcmd:-}" ]; then
		return 0
	fi

	command_for_audit="$(last_history_command_for_audit)" || return 0
	ensure_audit_history_file || return 0
	audit_file="$(audit_history_file_path)"

	timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
	history_user="${BASH_HISTORY_USERNAME:-${USER:-unknown}}"
	history_user_display="$history_user"
	if [ "${#history_user_display}" -gt 24 ]; then
		history_user_display="${history_user_display:0:21}..."
	fi
	cmd_exit="${last_cmd_exit_code:-0}"
	duration_us="${_last_cmd_us:-0}"
	duration_display="$(format_duration_us "$duration_us")"

	if printf '%-24s  %-24s  exit:%-3s  took:%-9s  %s\n' \
		"$timestamp" "$history_user_display" "$cmd_exit" "$duration_display" "$command_for_audit" >> "$audit_file"; then
		__dotfiles_last_audit_histcmd="$current_histcmd"
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

function check_for_dot_env {
	# Unload prev .env if any
	if [ -n "$OLDPWD" ] && [ -f "$OLDPWD/.env" ]; then
		local env_vars=()
		while IFS= read -r line; do
			if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]]; then
				env_vars+=("${BASH_REMATCH[2]}")
			fi
		done < "$OLDPWD/.env"
		if [ "${#env_vars[@]}" -gt 0 ]; then
			unset "${env_vars[@]}"
		fi
	fi

	if [ -e .env ]; then
		set -o allexport
		source .env
		set +o allexport
		echo "Loaded .env"
	fi
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
__dotfiles_last_audit_histcmd=''
__dotfiles_prompt_last_exit_code=0

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
	if [[ "${DOTFILES_FEATURE_AUTO_DOT_ENV:-true}" == "true" ]]; then
		check_for_dot_env
	elif [[ "$DOTFILES_DEBUG" == "true" && "${DOTFILES_DEBUG_PROMPT_VERBOSE:-false}" == "true" ]]; then
		dotfiles_dbg "do_my_checks skipped check_for_dot_env (DOTFILES_FEATURE_AUTO_DOT_ENV=false)"
	fi

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
dotfiles_dbg ".FUNCTIONS feature summary: profile=${DOTFILES_FEATURE_PROFILE:-unset} custom_prompt=${DOTFILES_FEATURE_CUSTOM_PROMPT:-unset} metadata_mode=${DOTFILES_FEATURE_PROMPT_METADATA_MODE:-unset} track_duration=${DOTFILES_FEATURE_TRACK_COMMAND_DURATION:-unset} track_method=${DOTFILES_FEATURE_TRACK_COMMAND_DURATION_METHOD:-unset} local_history=${DOTFILES_FEATURE_LOCAL_HISTORY:-unset} auto_dot_env=${DOTFILES_FEATURE_AUTO_DOT_ENV:-unset}"


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
