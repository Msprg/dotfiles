#!/usr/bin/env bash
# Networking, media, and platform integration helpers.

function aac2mp3() {
	local aac_file="$1"
	local mp3_file
	local wav_file

	wav_file="$(mktemp --suffix=.wav)" || return 1
	mp3_file="$(basename "$aac_file" .aac).mp3"
	ffmpeg -y -i "$aac_file" "$wav_file" && \
	ffmpeg -i "$wav_file" -acodec libmp3lame "$mp3_file"
	rm -f "$wav_file"
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

function svgoo() {
	if [ "$#" -eq 0 ]; then
		echo 'Gimme an SVG file to optimize, please!'
		return 1
	fi

	if ! command -v svgo > /dev/null 2>&1; then
		echo "svgoo: 'svgo' executable not found"
		return 2
	fi

	local file="$1"
	svgo --input="$file" --pretty
}

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

# Start an HTTP server from a directory, optionally specifying the port
function server() {
	local port="${1:-8000}"
	local copyparty_cmd=""
	local copyparty_bin=""
	local sfx_locations=(
		"/usr/local/bin/copyparty-sfx.py"
		"${HOME}/.local/bin/copyparty-sfx.py"
	)

	# 1) Prefer a PATH-installed copyparty (pipx, package manager, etc.).
	# Use `type -P` so alias/function wrappers don't shadow the real executable.
	copyparty_bin="$(type -P copyparty 2> /dev/null || true)"
	if [[ -n "$copyparty_bin" ]]; then
		copyparty_cmd="$copyparty_bin"
	else
		# 2) Look for the standalone SFX in well-known locations.
		local loc
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
		&& [[ -n "$(find -L "$cmd_path" -mtime +7 2> /dev/null)" ]]; then
		local local_ver remote_ver latest_url
		local_ver="$("$copyparty_cmd" --version 2>&1 \
			| grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
		latest_url="$(curl -fsSL --connect-timeout 3 --max-time 5 \
			-o /dev/null -w '%{url_effective}' \
			"https://github.com/9001/copyparty/releases/latest" 2> /dev/null)"
		remote_ver="$(echo "$latest_url" \
			| grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"

		if [[ -n "$local_ver" && -n "$remote_ver" ]]; then
			if [[ "$local_ver" == "$remote_ver" ]]; then
				# Already up to date — reset the check timer.
				echo "Already up to date!"
				touch "$cmd_path" 2> /dev/null
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
				touch "$cmd_path" 2> /dev/null
			fi
		else
			# Could not determine versions (no internet?); reset timer to avoid
			# repeated slow checks on every invocation.
			touch "$cmd_path" 2> /dev/null
		fi
	fi

	# Start copyparty in the current directory; pass through any extra arguments.
	shift
	"$copyparty_cmd" -p "$port" "$@"
}
alias copyparty='server'

# Run `dig` and display the most useful info
function digga() {
	dig +nocmd "$1" any +multiline +noall +answer
}

# Show all the names (CNs and SANs) listed in the SSL certificate
# for a given domain
function getcertnames() {
	if [ -z "${1}" ]; then
		echo "ERROR: No domain specified."
		return 1
	fi

	local domain="${1}"
	local tmp
	local cert_text

	echo "Testing ${domain}…"
	echo ""

	tmp="$(echo -e "GET / HTTP/1.0\nEOT" \
		| openssl s_client -connect "${domain}:443" -servername "${domain}" 2>&1)"

	if [[ "${tmp}" = *"-----BEGIN CERTIFICATE-----"* ]]; then
		cert_text="$(echo "${tmp}" \
			| openssl x509 -text -certopt "no_aux, no_header, no_issuer, no_pubkey, \
			no_serial, no_sigdump, no_signame, no_validity, no_version")"
		echo "Common Name:"
		echo ""
		echo "${cert_text}" | grep "Subject:" | sed -e "s/^.*CN=//" | sed -e "s/\/emailAddress=.*//"
		echo ""
		echo "Subject Alternative Name(s):"
		echo ""
		echo "${cert_text}" | grep -A 1 "Subject Alternative Name:" \
			| sed -e "2s/DNS://g" -e "s/ //g" | tr "," "\n" | tail -n +2
		return 0
	fi

	echo "ERROR: Certificate not found."
	return 1
}

# Normalize `open` across Linux, macOS, and Windows.
# This is needed to make the `o` function (see below) cross-platform.
if [ "$(uname -s)" != 'Darwin' ]; then
	if grep -q Microsoft /proc/version; then
		# Ubuntu on Windows using the Linux subsystem
		alias open='explorer.exe'
	else
		alias open='xdg-open'
	fi
fi

# `o` with no arguments opens the current directory, otherwise opens the given
# location
function o() {
	if [ $# -eq 0 ]; then
		open .
	else
		open "$@"
	fi
}
