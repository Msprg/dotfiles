#!/usr/bin/env bash
# Search, file inspection, and lightweight editing helpers.

function q() {
	local wildcard="$1"
	local dot_file=".qignore"
	local ignore_dirs=(".git")
	local ignore_dir
	local prune_args=()
	local search_dirs=()
	local ignore_dirs_re

	shift

	if [ -f "$dot_file" ]; then
		while IFS= read -r ignore_dir || [ -n "$ignore_dir" ]; do
			[ -n "$ignore_dir" ] || continue
			ignore_dirs+=("${ignore_dir%/}")
		done < "$dot_file"
	fi

	for ignore_dir in "${ignore_dirs[@]}"; do
		prune_args+=(-path "./$ignore_dir" -prune -o)
	done

	if [ "$#" -gt 0 ]; then
		search_dirs=("$@")
	else
		search_dirs=(.)
	fi

	ignore_dirs_re="$(printf '%s|' "${ignore_dirs[@]}")"
	ignore_dirs_re="${ignore_dirs_re%|}"
	find "${search_dirs[@]}" "${prune_args[@]}" -name "$wildcard" | grep -Pv "^./(${ignore_dirs_re})$"
}

function f() {
	local dot_file=".grepignore"
	local column_count="${COLUMNS:-80}"
	local max_line_length
	local ignore_dirs=(".git" ".svn" "node_modules" "bower_components")
	local ignore_files=(".bash_history" ".viminfo")
	local exclude_args=()
	local grep_cmd="grep"
	local line

	if [ "$#" -eq 0 ]; then
		echo 'Find what?'
		return 0
	fi

	if ! [[ "$column_count" =~ ^[0-9]+$ ]] || [ "$column_count" -le 0 ]; then
		column_count=80
	fi
	max_line_length=$((column_count * 3))

	if [ -f "$dot_file" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			[ -n "$line" ] || continue
			if [[ "$line" == */ ]]; then
				ignore_dirs+=("${line%/}")
			else
				ignore_files+=("$line")
			fi
		done < "$dot_file"
	fi

	for line in "${ignore_dirs[@]}"; do
		exclude_args+=(--exclude-dir="$line")
	done

	for line in "${ignore_files[@]}"; do
		exclude_args+=(--exclude="$line")
	done

	# Preserve the legacy DEBUG switch while providing a narrowly scoped option.
	if [[ "${DOTFILES_DEBUG_FIND:-false}" == "true" ]] || [[ -v DEBUG ]]; then
		grep_cmd="echo grep"
		max_line_length=$((column_count * 30))
	fi

	$grep_cmd \
		--color="${GREP_COLOR:-always}" \
		--line-number \
		--binary-files=without-match \
		--recursive \
		"${exclude_args[@]}" "$@" \
		| cut -c -"${max_line_length}"
}

function inith() {
	if [ ! -e .bash_history ]; then
		touch .bash_history
		check_for_local_history
	else
		echo ".bash_history already exists"
	fi
}

function initv() {
	local viminfo_config="set viminfo+=n.viminfo"
	if [ ! -e .vimrc ]; then
		echo "$viminfo_config" > .vimrc
	else
		if grep -F "set viminfo" .vimrc; then
			echo ".viminfo already configured"
		else
			echo "$viminfo_config" >> .vimrc
			echo ".viminfo configured"
		fi
	fi
}

function skip {
	tail --lines +"$(( $1 + 1 ))"
}

function vimp {
	local file="$1"
	local line_number=''

	# Accept both path:line and grep-style path:line:matching text inputs.
	if [[ "$file" =~ :([0-9]+)(:.*)?$ ]]; then
		file="${file%"${BASH_REMATCH[0]}"}"
		line_number="+${BASH_REMATCH[1]}"
		vim "$file" "$line_number"
	else
		vim "$@"
	fi
}

function source_location {
	shopt -s extdebug
	declare -F "$1"
	shopt -u extdebug
}

function second {
	awk '{ print $2; }'
}

# Given a list of files to STDIN, will filter out the ones that contain the grep needle.
function does_not_contain {
	local needle="$1"
	local file

	while IFS= read -r file; do
		grep "$needle" "$file" > /dev/null || echo "$file"
	done
}

export -f does_not_contain

function seconds { date -u +%H:%M:%S -d "@$1"; }

# Create a .tar.gz archive, using `zopfli`, `pigz` or `gzip` for compression
function targz() {
	local target
	local tmp_file
	local size
	local cmd=''
	local zipped_size

	target="${1%/}"
	tmp_file="${target}.tar"
	tar -cvf "${tmp_file}" --exclude=".DS_Store" "$@" || return 1

	size=$(
		stat -f"%z" "${tmp_file}" 2> /dev/null
		stat -c"%s" "${tmp_file}" 2> /dev/null
	)

	if (( size < 52428800 )) && hash zopfli 2> /dev/null; then
		cmd="zopfli"
	elif hash pigz 2> /dev/null; then
		cmd="pigz"
	else
		cmd="gzip"
	fi

	echo "Compressing .tar ($((size / 1000)) kB) using \`${cmd}\`…"
	"${cmd}" -v "${tmp_file}" || return 1
	[ -f "${tmp_file}" ] && rm "${tmp_file}"

	zipped_size=$(
		stat -f"%z" "${tmp_file}.gz" 2> /dev/null
		stat -c"%s" "${tmp_file}.gz" 2> /dev/null
	)

	echo "${tmp_file}.gz ($((zipped_size / 1000)) kB) created successfully."
}

# Use Git’s colored diff when available
if hash git &>/dev/null; then
	function diff() {
		git diff --no-index --color-words "$@"
	}
fi

# Create a data URL from a file
function dataurl() {
	local mime_type

	mime_type="$(file -b --mime-type "$1")"
	if [[ $mime_type == text/* ]]; then
		mime_type="${mime_type};charset=utf-8"
	fi
	echo "data:${mime_type};base64,$(openssl base64 -in "$1" | tr -d '\n')"
}

# Compare original and gzipped file size
function gz() {
	local origsize
	local gzipsize
	local ratio

	origsize="$(wc -c < "$1")"
	gzipsize="$(gzip -c "$1" | wc -c)"
	ratio="$(echo "$gzipsize * 100 / $origsize" | bc -l)"
	printf "orig: %d bytes\n" "$origsize"
	printf "gzip: %d bytes (%2.2f%%)\n" "$gzipsize" "$ratio"
}

# `tre` is a shorthand for `tree` with hidden files and color enabled, ignoring
# the `.git` directory, listing directories first. The output gets piped into
# `less` with options to preserve color and line numbers, unless the output is
# small enough for one screen.
function tre() {
	tree -aC -I '.git|node_modules|bower_components' --dirsfirst "$@" | less -FRNX
}
