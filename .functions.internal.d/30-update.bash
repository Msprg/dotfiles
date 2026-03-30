#!/usr/bin/env bash
# Dotfiles repo resolution and asynchronous update notices.

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
