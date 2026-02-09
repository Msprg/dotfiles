#!/usr/bin/env bash
# User-facing interactive functions and related command aliases.

# Create a new directory and enter it
function mkd() {
	mkdir -p "$@" && cd "$_" || return;
}

# Determine size of a file or total size of a directory
function fs() {
	if du -b /dev/null > /dev/null 2>&1; then
		local arg=-scbhk;
	else
		local arg=-schk;
	fi
	if [[ -n "$@" ]]; then
		du $arg -- "$@";
	else
		du $arg .[^.]* ./*;
	fi;
}

# Print non-loopback interface addresses as: iface IPv4... IPv6...
function ips() {
	if ! command -v ip > /dev/null 2>&1; then
		echo "ips: 'ip' command not found" >&2
		return 1
	fi

	ip -o addr show | awk '
		$2 == "lo" { next }
		$3 == "inet" {
			ipv4[$2] = ipv4[$2] (ipv4[$2] ? " " : "") $4
			if (!seen[$2]++) order[++count] = $2
			next
		}
		$3 == "inet6" {
			ipv6[$2] = ipv6[$2] (ipv6[$2] ? " " : "") $4
			if (!seen[$2]++) order[++count] = $2
		}
		END {
			for (i = 1; i <= count; i++) {
				iface = order[i]
				if (!ipv4[iface] && !ipv6[iface]) {
					continue
				}

				line = iface
				if (ipv4[iface]) line = line " " ipv4[iface]
				if (ipv6[iface]) line = line " " ipv6[iface]
				print line
			}
		}
	'
}

function catt() {
	for i in "$@"; do
		if [[ -d "$i" ]]; then
			ls "$i"
		else
			cat "$i"
		fi
	done
}

ports() { if [[ -z "$*" ]]; then sudo netstat -pna; else sudo netstat -pna | grep -i "$@"; fi }

function audit_bash_history {
	local audit_file

	audit_file="$(audit_history_file_path)"
	if [ ! -s "$audit_file" ]; then
		echo "No audit history found at $audit_file"
		return 0
	fi

	if [ "$#" -eq 0 ]; then
		nl -ba "$audit_file"
		return
	fi

	if [ "$#" -eq 1 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
		tail -n "$1" "$audit_file" | nl -ba
		return
	fi

	echo "Usage: audit_bash_history [N]"
	return 1
}

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

#export RUBY_GC_MALLOC_LIMIT=90000000
#export RUBY_GC_HEAP_FREE_SLOTS=200000

# brew
#BREW_PREFIX=$(/opt/homebrew/bin/brew --prefix)
#
#if [ `arch` = 'i386' ]; then
#	echo "Rosetta"
#	BREW_PREFIX=$(/usr/local/homebrew/bin/brew --prefix)
#fi
#
#export PATH="$BREW_PREFIX/opt/coreutils/libexec/gnubin:$PATH"
#export PATH="$BREW_PREFIX/opt/findutils/libexec/gnubin:$PATH"
#export PATH="$BREW_PREFIX/opt/grep/libexec/gnubin:$PATH"
#export PATH="$BREW_PREFIX/opt/grep/libexec/gnubin:$PATH"
#export PATH="$BREW_PREFIX/opt/gnu-sed/libexec/gnubin:$PATH"
#export PATH="$BREW_PREFIX/opt/python/libexec/bin:$PATH"
#export MANPATH="$BREW_PREFIX/opt/coreutils/libexec/gnuman:$MANPATH"

# node
#export PATH="./node_modules/.bin:$PATH"

# Ruby gems
#export PATH=$PATH:~/.gem/ruby/2.6.0/bin

#export LC_ALL=en_US.UTF-8
#export LANG=en_US.UTF-8

function pull() {
	if [ ! -d .git ]; then
		echo "Not a Git repo."
		return 1
	fi

	if [ $# -eq 0 ]; then
		if [ "`git status --short --branch | head -1 | grep -o '(no branch)'`" = "(no branch)" ]; then
			echo "Not on a branch."
			return 1
		fi

		# If there is a tracked branch only pull that one
		git status --short --branch |\
		head -1 |\
		grep -oP '\.{3}\K\S+' |\
		sed 's|/| |' |\
		xargs git pull
	else
		git pull "$@"
	fi
}

function q() {
	local wildcard="$1"
	shift
	local dirs="$@"

	local IGNORE_DIRS=".git"
	local DOT_FILE=".qignore"
	local EXCLUDE_DIR_CLAUSE=""

	if [ -f $DOT_FILE ]; then
		IGNORE_DIRS+=" "`cat "$DOT_FILE" | paste -sd " "`
	fi

	local IGNORE_DIRS_RE=${IGNORE_DIRS// /\|}

	for DIR in $IGNORE_DIRS; do
		EXCLUDE_DIR_CLAUSE+=" -path ./$DIR -prune -o"
	done

	find ${dirs:-.} $EXCLUDE_DIR_CLAUSE -name "$wildcard" \
		| grep -Pv "^./($IGNORE_DIRS_RE)$"
}

function aac2mp3() {
	aac_file=$1
	mp3_file=$(basename "$aac_file" .aac).mp3
	wav_file=/tmp/aac2mp3.wav
	ffmpeg -i "$aac_file" "$wav_file" && \
	ffmpeg -i "$wav_file" -acodec libmp3lame "$mp3_file" && \
	rm "$wav_file"
}

function f() {
	if [ "$#" -eq 0 ]; then
		echo 'Find what?'
		return 0
	fi

	local DOT_FILE=".grepignore"
	local MAX_LINE_LENGTH=$(($COLUMNS * 3))

	local IGNORE_DIRS=".git .svn node_modules bower_components"
	local IGNORE_FILES=".bash_history .viminfo"
	local EXCLUDE_DIR_CLAUSE=""
	local EXCLUDE_CLAUSE=""

	if [ -f $DOT_FILE ]; then
		IGNORE_DIRS+=" $(echo $(grep '/$' $DOT_FILE | sed 's|/$||'))"
		IGNORE_FILES+=" $(echo $(grep -v '/$' $DOT_FILE))"
	fi

	for DIR in $IGNORE_DIRS; do
		EXCLUDE_DIR_CLAUSE+=" --exclude-dir=$DIR"
	done

	for FILE in $IGNORE_FILES; do
		EXCLUDE_CLAUSE+=" --exclude=$FILE"
	done

	local GREP="grep"

	if [ -v DEBUG ]; then
		GREP="echo grep"
		MAX_LINE_LENGTH=$(($COLUMNS * 30))
	fi

	$GREP \
		--color=${GREP_COLOR:-always} \
		--line-number \
		--binary-files=without-match \
		--recursive \
		$EXCLUDE_CLAUSE \
		$EXCLUDE_DIR_CLAUSE "$@" \
		| cut -c -$MAX_LINE_LENGTH
}

function togif() {
	if [ "$#" -eq 0 ]; then
		echo 'Gif what?'
		return 0
	fi

	local input="$1"
	local filename="${input%.*}"

	ffmpeg -i "$input" -pix_fmt rgb24 -r 10 -f gif - | gifsicle --loopcount=forever --optimize=3 --delay=5 > "$filename.gif"
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

function svgoo() {
	if [ "$#" -eq 0 ]; then
		echo 'Gimme an SVG file to optimize, please!'
		return 1
	fi

	if ! which -s svgo; then
		echo 'I’m not seeing your svgo executable...🤔'
		return 2
	fi

	local file="$1"
	svgo --input="$file" --pretty
}

function is_interactive_shell() {
	# https://www.gnu.org/software/bash/manual/html_node/Is-this-Shell-Interactive_003f.html
	[[ "$-" =~ "i" ]]
}

if is_interactive_shell; then
	# fzf git branch name; use like this: git checkout ^g^b
	bind '"\C-g\C-b": "$(git branch -a | cut -c 3- | fzf)\e\C-e"'
fi

#fzf
export FZF_CTRL_T_COMMAND="fd --type f"

function hibp() {
	local password_hash
	local head
	local tail
	local tempfile

	echo "This will locally compute hash of entered password, and then send only a part of that hash for verification to haveibeenpwned.com"
	read -r -s -p "Password: " p
	password_hash="$(printf '%s' "$p" | openssl sha1 | awk '{print $2}')"
	unset p
	echo
	password_hash="${password_hash^^}"
	head="${password_hash:0:5}"
	tail="${password_hash:5:35}"

	tempfile="$(mktemp)"

	if curl -s "https://api.pwnedpasswords.com/range/$head" --output "$tempfile"; then
		if grep --ignore-case -q "^${tail}:" "$tempfile"; then
			echo -e "${ANSI_red_bg}${ANSI_bold}PWNED!${reset}"
		else
			echo -e "${ANSI_green_bg}NOT PWNED${reset}"
		fi
	fi
	rm -f "$tempfile"
}

#function log {
#	local directory=~/Google\ Drive/log
#	local filename="`LC_ALL=ro_RO.utf-8 date +%F-%H-%M-%a`.txt"
#	local variation="$1"
#	local template="template.txt"
#
#	if [ $variation ]; then
#	    template="template-$variation.txt"
#	fi
#
#	cp "$directory/$template" "$directory/$filename"
#	cd "$directory"
#	code --new-window . "$filename" && exit
#}

function skip {
	tail --lines +$(expr "$1" + 1)
}

function vimp {
	file=$1
	line_number=`expr "$file" : '.*:\([0-9]\+\)'`

	if [[ "$file" =~ :[0-9]*.*$ ]]; then
		file=${file/$BASH_REMATCH/}
		line_number=$BASH_REMATCH
		line_number=${line_number/:/}
		line_number=${line_number/[^0-9]*/}

		if [[ "$line_number" -ne "" ]]; then
			line_number="+$line_number"
		fi

		vim "$file" $line_number
	else
		vim "$@"
	fi
}

function source_location {
	shopt -s extdebug
	declare -F $1
	shopt -u extdebug
}

function gfc {
	local origin_branch_name="$1"

	git fetch origin $origin_branch_name
	git checkout $origin_branch_name
	git reset --hard origin/$origin_branch_name
}

#function s {
#	local files="$@"
#
#	stat -c "%s %n" $files | numfmt --to=iec-i --suffix=B --padding=7
#}

function second {
	awk '{ print $2; }'
}

# Given a list of files to STDIN, will filter out the ones that contain the grep needle.
function does_not_contain {
	local needle=$1

	while read file; do
		grep "$needle" "$file" > /dev/null || echo "$file"
	done
}

export -f does_not_contain

function seconds { date -u +%H:%M:%S -d @$1; }





# Change working directory to the top-most Finder window location
#function cdf() { # short for `cdfinder`
#	cd "$(osascript -e 'tell app "Finder" to POSIX path of (insertion location as alias)')";
#}

# Create a .tar.gz archive, using `zopfli`, `pigz` or `gzip` for compression
function targz() {
	local tmpFile="${@%/}.tar";
	tar -cvf "${tmpFile}" --exclude=".DS_Store" "${@}" || return 1;

	size=$(
		stat -f"%z" "${tmpFile}" 2> /dev/null; # macOS `stat`
		stat -c"%s" "${tmpFile}" 2> /dev/null;  # GNU `stat`
	);

	local cmd="";
	if (( size < 52428800 )) && hash zopfli 2> /dev/null; then
		# the .tar file is smaller than 50 MB and Zopfli is available; use it
		cmd="zopfli";
	else
		if hash pigz 2> /dev/null; then
			cmd="pigz";
		else
			cmd="gzip";
		fi;
	fi;

	echo "Compressing .tar ($((size / 1000)) kB) using \`${cmd}\`…";
	"${cmd}" -v "${tmpFile}" || return 1;
	[ -f "${tmpFile}" ] && rm "${tmpFile}";

	zippedSize=$(
		stat -f"%z" "${tmpFile}.gz" 2> /dev/null; # macOS `stat`
		stat -c"%s" "${tmpFile}.gz" 2> /dev/null; # GNU `stat`
	);

	echo "${tmpFile}.gz ($((zippedSize / 1000)) kB) created successfully.";
}

# Use Git’s colored diff when available
hash git &>/dev/null;
if [ $? -eq 0 ]; then
	function diff() {
		git diff --no-index --color-words "$@";
	}
fi;

# Create a data URL from a file
function dataurl() {
	local mimeType=$(file -b --mime-type "$1");
	if [[ $mimeType == text/* ]]; then
		mimeType="${mimeType};charset=utf-8";
	fi
	echo "data:${mimeType};base64,$(openssl base64 -in "$1" | tr -d '\n')";
}

# Start an HTTP server from a directory, optionally specifying the port
function server() {
	local port="${1:-8000}";
	local url="http://localhost:${port}/"
	local copyparty_cmd=""
	local copyparty_bin=""
	local sfx_locations=(
		"/usr/local/bin/copyparty-sfx.py"
		"${HOME}/.local/bin/copyparty-sfx.py"
	)

	# 1) Prefer a PATH-installed copyparty (pipx, package manager, etc.).
	# Use `type -P` so alias/function wrappers don't shadow the real executable.
	copyparty_bin="$(type -P copyparty 2>/dev/null || true)"
	if [[ -n "$copyparty_bin" ]]; then
		copyparty_cmd="$copyparty_bin"
	else
		# 2) Look for the standalone SFX in well-known locations.
		for loc in "${sfx_locations[@]}"; do
			if [[ -f "$loc" && -x "$loc" ]]; then
				copyparty_cmd="$loc"
				break
			fi
		done
	fi

	# 3) Not found anywhere — offer to download the standalone SFX release.
	if [[ -z "$copyparty_cmd" ]]; then
		local dl_url="https://github.com/9001/copyparty/releases/latest/download/copyparty-sfx.py"
		local dest=""

		# Prefer system-wide /usr/local/bin when writable; fall back to ~/.local/bin.
		if [[ -w "/usr/local/bin" ]]; then
			dest="/usr/local/bin/copyparty-sfx.py"
		else
			dest="${HOME}/.local/bin/copyparty-sfx.py"
		fi

		echo "copyparty is not installed."
		echo ""
		echo "Download the standalone release to ${dest}?"
		echo "  ${dl_url}"
		echo ""
		read -rp "Download now? [y/N] " answer
		if [[ "$answer" =~ ^[Yy]$ ]]; then
			mkdir -p "$(dirname "$dest")"
			curl -fsSL "$dl_url" -o "$dest" && chmod +x "$dest" \
				|| { echo "Download failed."; return 1; }
			copyparty_cmd="$dest"
		else
			return 1
		fi
	fi

	# 4) Periodically check for a newer release (at most once per week).
	local cmd_path
	cmd_path="$copyparty_cmd"
	if [[ -n "$cmd_path" && -f "$cmd_path" ]] \
		&& [[ -n "$(find -L "$cmd_path" -mtime +7 2>/dev/null)" ]]; then
		local local_ver remote_ver latest_url
		local_ver="$("$copyparty_cmd" --version 2>&1 \
			| grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
		latest_url="$(curl -fsSL --connect-timeout 3 --max-time 5 \
			-o /dev/null -w '%{url_effective}' \
			"https://github.com/9001/copyparty/releases/latest" 2>/dev/null)"
		remote_ver="$(echo "$latest_url" \
			| grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"

		if [[ -n "$local_ver" && -n "$remote_ver" ]]; then
			if [[ "$local_ver" == "$remote_ver" ]]; then
				# Already up to date — reset the check timer.
				echo "Already up to date!"
				touch "$cmd_path" 2>/dev/null
			else
				echo "copyparty update available: ${local_ver} → ${remote_ver}"
				echo "  https://github.com/9001/copyparty/releases/latest"
				if [[ "$cmd_path" == *copyparty-sfx.py ]]; then
					read -rp "Update now? [y/N] " update_answer
					if [[ "$update_answer" =~ ^[Yy]$ ]]; then
						curl -fsSL --connect-timeout 5 --max-time 30 \
							"https://github.com/9001/copyparty/releases/latest/download/copyparty-sfx.py" \
							-o "$cmd_path" && chmod +x "$cmd_path" \
							&& echo "Updated to ${remote_ver}." \
							|| echo "Update failed; continuing with current version."
					fi
				else
					echo "  Update with: pipx upgrade copyparty"
				fi
				# Touch even if the user declined, to avoid nagging until next period.
				touch "$cmd_path" 2>/dev/null
			fi
		else
			# Could not determine versions (no internet?); reset timer to avoid
			# repeated slow checks on every invocation.
			touch "$cmd_path" 2>/dev/null
		fi
	fi

	# Start copyparty in the current directory; pass through any extra arguments.
	shift
	"$copyparty_cmd" -p "$port" "$@";
}
alias copyparty='server'

# Start a PHP server from a directory, optionally specifying the port
# (Requires PHP 5.4.0+.)
#function phpserver() {
#	local port="${1:-4000}";
#	local ip=$(ipconfig getifaddr en1);
#	sleep 1 && open "http://${ip}:${port}/" &
#	php -S "${ip}:${port}";
#}

# Compare original and gzipped file size
function gz() {
	local origsize=$(wc -c < "$1");
	local gzipsize=$(gzip -c "$1" | wc -c);
	local ratio=$(echo "$gzipsize * 100 / $origsize" | bc -l);
	printf "orig: %d bytes\n" "$origsize";
	printf "gzip: %d bytes (%2.2f%%)\n" "$gzipsize" "$ratio";
}

# Run `dig` and display the most useful info
function digga() {
	dig +nocmd "$1" any +multiline +noall +answer;
}

# Show all the names (CNs and SANs) listed in the SSL certificate
# for a given domain
function getcertnames() {
	if [ -z "${1}" ]; then
		echo "ERROR: No domain specified.";
		return 1;
	fi;

	local domain="${1}";
	echo "Testing ${domain}…";
	echo ""; # newline

	local tmp=$(echo -e "GET / HTTP/1.0\nEOT" \
		| openssl s_client -connect "${domain}:443" -servername "${domain}" 2>&1);

	if [[ "${tmp}" = *"-----BEGIN CERTIFICATE-----"* ]]; then
		local certText=$(echo "${tmp}" \
			| openssl x509 -text -certopt "no_aux, no_header, no_issuer, no_pubkey, \
			no_serial, no_sigdump, no_signame, no_validity, no_version");
		echo "Common Name:";
		echo ""; # newline
		echo "${certText}" | grep "Subject:" | sed -e "s/^.*CN=//" | sed -e "s/\/emailAddress=.*//";
		echo ""; # newline
		echo "Subject Alternative Name(s):";
		echo ""; # newline
		echo "${certText}" | grep -A 1 "Subject Alternative Name:" \
			| sed -e "2s/DNS://g" -e "s/ //g" | tr "," "\n" | tail -n +2;
		return 0;
	else
		echo "ERROR: Certificate not found.";
		return 1;
	fi;
}

# Normalize `open` across Linux, macOS, and Windows.
# This is needed to make the `o` function (see below) cross-platform.
if [ ! $(uname -s) = 'Darwin' ]; then
	if grep -q Microsoft /proc/version; then
		# Ubuntu on Windows using the Linux subsystem
		alias open='explorer.exe';
	else
		alias open='xdg-open';
	fi
fi

# `o` with no arguments opens the current directory, otherwise opens the given
# location
function o() {
	if [ $# -eq 0 ]; then
		open .;
	else
		open "$@";
	fi;
}

# `tre` is a shorthand for `tree` with hidden files and color enabled, ignoring
# the `.git` directory, listing directories first. The output gets piped into
# `less` with options to preserve color and line numbers, unless the output is
# small enough for one screen.
function tre() {
	tree -aC -I '.git|node_modules|bower_components' --dirsfirst "$@" | less -FRNX;
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

function gdv() {
	git diff --ignore-all-space "$@" | vim -R -
}

function get_default_branch() {
	if git branch | grep -q '^. main\s*$'; then
		echo main
	else
		echo master
	fi
}
