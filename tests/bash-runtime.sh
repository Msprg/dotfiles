#!/usr/bin/env bash
# Runtime validation for the unified dotfiles: loaders, profiles, bootstrap
# scopes, migration safety, update pipeline, and the command audit.
# Run: bash tests/bash-runtime.sh   (no root required; fixtures via env knobs)

set -u

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_dir="$repo_dir/.config/dotfiles"
test_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-runtime-test.XXXXXX")" || exit 1
tests_run=0

function cleanup {
	rm -rf "$test_tmp_dir"
}
trap cleanup EXIT

function fail {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

function pass {
	tests_run=$((tests_run + 1))
	printf 'ok %d - %s\n' "$tests_run" "$1"
}

function assert_function {
	declare -F "$1" > /dev/null || fail "expected function '$1' to be loaded"
}

# Fixture home carrying the rc stubs; runtime loaded from the repo.
stub_home="$test_tmp_dir/stub-home"
mkdir -p "$stub_home"
cp "$repo_dir/.bash_profile" "$repo_dir/.bashrc" "$stub_home/"

#!SECTION syntax
for shell_file in \
	"$runtime_dir/functions.internal.d/"*.bash \
	"$runtime_dir/functions.external.d/"*.bash \
	"$runtime_dir/functions" \
	"$runtime_dir/functions.internal.bash" \
	"$runtime_dir/functions.external.bash" \
	"$runtime_dir/bash_profile" \
	"$runtime_dir/agent_guard" \
	"$runtime_dir/agent_audit" \
	"$runtime_dir/features" \
	"$runtime_dir/exports" \
	"$runtime_dir/prompt" \
	"$runtime_dir/path_defaults" \
	"$runtime_dir/local_additions" \
	"$runtime_dir/aliases/bash/aliases" \
	"$repo_dir/.bash_profile" \
	"$repo_dir/.bashrc" \
	"$repo_dir/bootstrap.sh" \
	"$repo_dir/init/claude-code-audit-hook.sh"; do
	bash -n "$shell_file" || fail "syntax check failed: $shell_file"
done
pass 'all runtime files have valid Bash syntax'

#!SECTION loader wiring
export DOTFILES_FEATURE_TRACK_COMMAND_DURATION=false
export DOTFILES_FEATURE_PROMPT_HOOKS=false
export DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK=false
export DOTFILES_FEATURE_HISTORY_AUDIT=false
export DOTFILES_DEBUG=false
source "$runtime_dir/functions" || fail 'complete runtime failed to load'
for function_name in \
	check_for_dot_env do_my_checks dotfiles_update audit_bash_history \
	audit_history_file_path agent_audit_history_file_path \
	append_bash_history_audit __dotfiles_debug_trap_hook \
	mkd f q pull gfc vimp server; do
	assert_function "$function_name"
done
unset function_name
pass 'complete runtime loads representative internal and external functions'

function vim {
	printf '<%s>\n' "$@"
}
vimp_output="$(vimp 'path with spaces/file.txt:42:matching text')"
expected_vimp_output=$'<path with spaces/file.txt>\n<+42>'
[ "$vimp_output" = "$expected_vimp_output" ] \
	|| fail "vimp did not parse grep-style input (got: $vimp_output)"
unset -f vim
pass 'vimp accepts grep-style path:line:text input'

search_fixture="$test_tmp_dir/search"
mkdir -p "$search_fixture/keep dir" "$search_fixture/ignored dir"
printf 'needle\n' > "$search_fixture/keep dir/hit.txt"
printf 'needle\n' > "$search_fixture/ignored dir/hidden.txt"
printf 'ignored dir/\n' > "$search_fixture/.grepignore"
printf 'ignored dir/\n' > "$search_fixture/.qignore"
f_output="$(cd "$search_fixture" && DOTFILES_DEBUG_FIND=false f needle .)"
[[ "$f_output" == *'keep dir/hit.txt'* ]] || fail 'f did not find the expected file'
[[ "$f_output" != *'ignored dir/hidden.txt'* ]] || fail 'f did not honor .grepignore'
q_output="$(cd "$search_fixture" && q '*.txt')"
[ "$q_output" = './keep dir/hit.txt' ] || fail "q did not honor .qignore (got: $q_output)"
pass 'f and q preserve ignore entries containing spaces'

f_debug_output="$(cd "$search_fixture" && DOTFILES_DEBUG_FIND=true f needle .)"
[[ "$f_debug_output" == grep\ --color=* ]] || fail 'DOTFILES_DEBUG_FIND=true did not enable find debugging'
pass 'f uses explicit true/false semantics for DOTFILES_DEBUG_FIND'

#!SECTION hard-required loaders
runtime_copy="$test_tmp_dir/runtime"
cp -R "$runtime_dir" "$runtime_copy"
rm "$runtime_copy/functions.internal.d/20-env.bash"
if loader_error="$(bash --noprofile --norc -c 'source "$1/functions"' _ "$runtime_copy" 2>&1)"; then
	fail 'runtime load succeeded with a required module missing'
fi
[[ "$loader_error" == *'required internal module is missing or unreadable'* ]] \
	|| fail "missing-module error was not actionable (got: $loader_error)"
pass 'missing required modules fail with an actionable error'

runtime_copy2="$test_tmp_dir/runtime2"
cp -R "$runtime_dir" "$runtime_copy2"
rm "$runtime_copy2/functions"
if profile_error="$(HOME="$stub_home" DOTFILES_HOME="$runtime_copy2" DOTFILES_AGENT_GUARD=false \
	bash --noprofile --norc -c 'source "$HOME/.bash_profile"' 2>&1)"; then
	fail 'full profile load succeeded without the required functions loader'
fi
[[ "$profile_error" == *'required configuration file is missing or unreadable'* ]] \
	|| fail "missing functions error was not actionable (got: $profile_error)"
pass 'full profile fails clearly when the runtime loader is missing'

#!SECTION profiles
profile_env=(HOME="$stub_home" TERM=dumb DOTFILES_HOME="$runtime_dir" DOTFILES_FEATURE_HISTORY_AUDIT=false)
env -i PATH="$PATH" "${profile_env[@]}" bash --noprofile --norc -i -c '
	source "$HOME/.bash_profile" >/dev/null 2>&1
	declare -F dotfiles_update >/dev/null || exit 1
	[ "$DOTFILES_FEATURE_PROFILE" = minimal ] || exit 1
	[ "$DOTFILES_FEATURE_PROMPT_HOOKS" = false ] || exit 1
	[ "$DOTFILES_FEATURE_AUTO_DOT_ENV" = false ] || exit 1
	[ "$DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK" = false ] || exit 1
	[ "$DOTFILES_INSTALL_SCOPE" = user ] || exit 1
' 2> /dev/null || fail 'default interactive load did not yield the minimal feature set'
pass 'default profile loads the conservative minimal feature set'

env -i PATH="$PATH" "${profile_env[@]}" DOTFILES_FEATURE_PROFILE=full bash --noprofile --norc -i -c '
	source "$HOME/.bash_profile" >/dev/null 2>&1
	[ "$DOTFILES_FEATURE_PROFILE" = full ] || exit 1
	[ "$DOTFILES_FEATURE_PROMPT_HOOKS" = true ] || exit 1
' 2> /dev/null || fail 'environment-requested full profile was not honored'
env -i PATH="$PATH" "${profile_env[@]}" DOTFILES_FEATURE_PROFILE=bogus bash --noprofile --norc -i -c '
	source "$HOME/.bash_profile" >/dev/null 2>&1
	[ "$DOTFILES_FEATURE_PROFILE" = minimal ] || exit 1
	[ "$DOTFILES_FEATURE_PROMPT_HOOKS" = false ] || exit 1
' 2> /dev/null || fail 'unknown environment profile was not rejected'
pass 'environment-requested profile is honored and validated'

# [regression] DOTFILES_FEATURE_PROFILE must not be exported: an exported value
# leaked into every child login shell (tmux pane, nested bash -l) and overrode
# the user's own features.local there. An explicitly-typed env value still wins
# for that one invocation, but a child that inherits nothing re-derives from the
# local file.
leak_home="$test_tmp_dir/profile-leak-home"
mkdir -p "$leak_home/.config/dotfiles"
cp "$repo_dir/.bash_profile" "$repo_dir/.bashrc" "$leak_home/"
printf 'DOTFILES_FEATURE_PROFILE=full\n' > "$leak_home/.config/dotfiles/features.local"
env -i PATH="$PATH" HOME="$leak_home" TERM=dumb DOTFILES_HOME="$runtime_dir" \
	DOTFILES_LOCAL_HOME="$leak_home/.config/dotfiles" DOTFILES_FEATURE_HISTORY_AUDIT=false \
	bash --noprofile --norc -i -c '
	source "$HOME/.bash_profile" >/dev/null 2>&1
	[ "$DOTFILES_FEATURE_PROFILE" = full ] || exit 1        # features.local chose full
	# The user switches back to minimal for future shells.
	printf "DOTFILES_FEATURE_PROFILE=minimal\n" > "$DOTFILES_LOCAL_HOME/features.local"
	# A child login shell must re-derive from features.local, not inherit an
	# exported profile from this parent.
	child="$(bash --noprofile --norc -i -c "source \$HOME/.bash_profile >/dev/null 2>&1; printf %s \"\$DOTFILES_FEATURE_PROFILE\"" 2>/dev/null)"
	[ "$child" = minimal ] || { printf "child=%s\n" "$child" >&2; exit 3; }
' 2> /dev/null || fail 'exported DOTFILES_FEATURE_PROFILE leaked into a child shell over features.local'
pass 'DOTFILES_FEATURE_PROFILE is not exported; child shells honor features.local'

env -i PATH="$PATH" HOME="$stub_home" TERM=dumb DOTFILES_HOME="$runtime_dir" BASH_SAFE_MODE=true \
	bash --noprofile --norc -i -c '
	source "$HOME/.bash_profile" >/dev/null 2>&1
	! declare -F dotfiles_update >/dev/null || exit 1
	[ -z "${PROMPT_COMMAND:-}" ] || exit 1
	[[ "$PS1" == "[safe]"* ]] || exit 1
' 2> /dev/null || fail 'safe mode loaded full runtime state'
pass 'safe profile excludes the full runtime'

#!SECTION agent guard via stub
env -i PATH="$PATH" HOME="$stub_home" TERM=dumb DOTFILES_HOME="$runtime_dir" CLAUDECODE=1 \
	bash --noprofile --norc -c '
	source "$HOME/.bash_profile" >/dev/null 2>&1
	[ "$DOTFILES_AGENT" = claude-code ] || exit 1
	[ -z "${PROMPT_COMMAND:-}" ] || exit 1
	! declare -F dotfiles_update >/dev/null || exit 1
	[ "$PAGER" = cat ] || exit 1
' || fail 'agent guard did not route a CLAUDECODE shell to the agent path'
env -i PATH="$PATH" HOME="$stub_home" TERM=dumb DOTFILES_HOME="$runtime_dir" \
	bash --noprofile --norc -c '
	source "$HOME/.bash_profile" >/dev/null 2>&1
	[ "$DOTFILES_AGENT" = non-interactive ] || exit 1
	! declare -F dotfiles_update >/dev/null || exit 1
' || fail 'plain non-interactive shell was not guarded'
pass 'agent guard routes agent and non-interactive shells to the lean path'

#!SECTION prompt-hook assembly
hook_env=(HOME="$stub_home" TERM=dumb DOTFILES_HOME="$runtime_dir")
env -i PATH="$PATH" "${hook_env[@]}" bash --noprofile --norc -i -c '
	source "$HOME/.bash_profile" >/dev/null 2>&1
	[ "$PROMPT_COMMAND" = "__dotfiles_audit_prompt_hook;__dotfiles_audit_capture_arm" ] || exit 1
	[[ "$(trap -p DEBUG)" == *__dotfiles_debug_trap_hook* ]] || exit 1
' 2> /dev/null || fail 'minimal profile did not install the lean audit hook'
env -i PATH="$PATH" "${hook_env[@]}" DOTFILES_FEATURE_PROFILE=full bash --noprofile --norc -i -c '
	source "$HOME/.bash_profile" >/dev/null 2>&1
	[[ "$PROMPT_COMMAND" == "capture_prompt_exit_status;"*"do_my_checks;__dotfiles_audit_capture_arm" ]] || exit 1
	[[ "$PROMPT_COMMAND" != *__dotfiles_audit_prompt_hook* ]] || exit 1
' 2> /dev/null || fail 'full profile did not assemble the audited prompt chain'
# Individual feature flags are deliberately NOT read from the environment
# (profiles apply deterministically); the per-user opt-out is features.local.
mkdir -p "$stub_home/.config/dotfiles"
printf 'DOTFILES_FEATURE_HISTORY_AUDIT=false\n' > "$stub_home/.config/dotfiles/features.local"
env -i PATH="$PATH" "${hook_env[@]}" bash --noprofile --norc -i -c '
	source "$HOME/.bash_profile" >/dev/null 2>&1
	[ -z "${PROMPT_COMMAND:-}" ] || exit 1
' 2> /dev/null || fail 'audit opt-out via features.local still installed a prompt hook'
rm "$stub_home/.config/dotfiles/features.local"
env -i PATH="$PATH" "${hook_env[@]}" bash --noprofile --norc -i -c '
	source "$HOME/.bash_profile" >/dev/null 2>&1
	first="$PROMPT_COMMAND"
	source "$DOTFILES_HOME/functions" >/dev/null 2>&1
	[ "$PROMPT_COMMAND" = "$first" ] || exit 1
' 2> /dev/null || fail 're-sourcing the runtime stacked prompt hooks'
pass 'prompt hooks assemble per profile and re-source idempotently'

# A distro ~/.bashrc runs after the profile.d hook and sets its own PS1. With
# the custom prompt enabled the runtime must win from the first prompt on;
# with it disabled (minimal) the distro prompt must stay untouched. One-shot:
# a PS1 changed by hand afterwards is respected.
env -i PATH="$PATH" "${hook_env[@]}" DOTFILES_FEATURE_PROFILE=full bash --noprofile --norc -i -c '
	source "$HOME/.bash_profile" >/dev/null 2>&1
	[ -n "${__dotfiles_custom_ps1:-}" ] || exit 1
	[[ "$PROMPT_COMMAND" == *__dotfiles_prompt_reapply* ]] || exit 1
	PS1="distro> "
	eval "$PROMPT_COMMAND" >/dev/null 2>&1
	[ "$PS1" = "$__dotfiles_custom_ps1" ] || exit 1
	PS1="by-hand> "
	eval "$PROMPT_COMMAND" >/dev/null 2>&1
	[ "$PS1" = "by-hand> " ] || exit 1
' 2> /dev/null || fail 'custom prompt did not re-apply over a later ~/.bashrc PS1 (or clobbered a manual PS1)'
env -i PATH="$PATH" "${hook_env[@]}" bash --noprofile --norc -i -c '
	source "$HOME/.bash_profile" >/dev/null 2>&1
	[ -z "${__dotfiles_custom_ps1:-}" ] || exit 1
	[[ "${PROMPT_COMMAND:-}" != *__dotfiles_prompt_reapply* ]] || exit 1
	PS1="distro> "
	eval "$PROMPT_COMMAND" >/dev/null 2>&1
	[ "$PS1" = "distro> " ] || exit 1
' 2> /dev/null || fail 'minimal profile touched PS1 set by a later ~/.bashrc'
pass 'custom prompt re-applies over a distro ~/.bashrc PS1 only when enabled'

# [regression] The DEBUG-trap timer must start on the USER's command, not on a
# PROMPT_COMMAND part — including one appended by another tool AFTER our chain
# (e.g. `history -a`). A PS0 marker sets the boundary flag right before the user
# command; prompt parts run with it cleared and must not arm the timer, or idle
# prompt time is counted as the next command's duration.
env -i PATH="$PATH" "${hook_env[@]}" DOTFILES_FEATURE_PROFILE=full bash --noprofile --norc -i -c '
	source "$HOME/.bash_profile" >/dev/null 2>&1
	[[ "$(trap -p DEBUG)" == *__dotfiles_debug_trap_hook* ]] || exit 1
	[ "${__dotfiles_prompt_boundary_active:-0}" = 1 ] || exit 2
	[[ "${PS0:-}" == *__dotfiles_at_user_command* ]] || exit 3
	# Another tool appends to PROMPT_COMMAND after our chain.
	PROMPT_COMMAND="$PROMPT_COMMAND; history -a"
	# A prompt cycle runs our parts AND the appended external part.
	eval "$PROMPT_COMMAND" >/dev/null 2>&1
	# After the prompt (before the user command) the timer must be unset and the
	# boundary cleared, even though history -a ran as a prompt part.
	[ -z "${timer_start:-}" ] || exit 4
	[ "${__dotfiles_at_user_command:-}" != 1 ] || exit 5
	# PS0 fires right before the user command, setting the boundary.
	__dotfiles_at_user_command=1
	true
	[ -n "${timer_start:-}" ] || exit 6
' 2> /dev/null || fail 'command timer must start on the user command, not on a (possibly appended) PROMPT_COMMAND part'
pass 'command timer starts on the user command via the PS0 boundary, not on prompt hooks (even appended ones)'

# [regression] multi-line PROMPT_COMMAND must not lose its tail to the ; split.
env -i PATH="$PATH" "${hook_env[@]}" DOTFILES_FEATURE_PROFILE=full bash --noprofile --norc -i -c '
	PROMPT_COMMAND=$'"'"'echo alpha\necho omega'"'"'
	source "$HOME/.bash_profile" >/dev/null 2>&1
	[[ "$PROMPT_COMMAND" == *"echo alpha"* ]] || exit 1
	[[ "$PROMPT_COMMAND" == *"echo omega"* ]] || exit 1
' 2> /dev/null || fail 'multi-line PROMPT_COMMAND tail was dropped by hook assembly'
pass 'multi-line PROMPT_COMMAND survives hook assembly'

# [regression] a newline in BASH_HISTORY_USERNAME must not forge audit records.
inject_home="$test_tmp_dir/inject-home"
inject_dir="$test_tmp_dir/inject-audit"
mkdir -p "$inject_home" "$inject_dir"
env -i PATH="$PATH" HOME="$inject_home" RT="$runtime_dir" ADIR="$inject_dir" bash --noprofile --norc -c '
	set -u
	function dotfiles_dbg { :; }
	source "$RT/functions.internal.d/00-common.bash"
	source "$RT/functions.internal.d/10-history.bash"
	export DOTFILES_AUDIT_DIR="$ADIR" DOTFILES_FEATURE_TRACK_COMMAND_DURATION=false
	printf -v evil "%s" "victim
2026-01-01T00:00:00+0000  forged                    exit:0    took:-           rm -rf /"
	export BASH_HISTORY_USERNAME="$evil"
	unset __dotfiles_audit_file_cached; audit_history_file_path > /dev/null
	AF="$(audit_history_file_path)"
	history -c; history -s "real-command"; last_cmd_exit_code=0
	append_bash_history_audit
	[ "$(wc -l < "$AF")" = 1 ] || exit 20
	! grep -q "forged" "$AF" || exit 21
	! grep -q "rm -rf /" "$AF" || exit 22
' || fail "newline in BASH_HISTORY_USERNAME forged an audit record (exit $?)"
pass 'newline in BASH_HISTORY_USERNAME cannot forge audit records'

# [regression] SSH-key identity follows a user across `su -`/`sudo su -` via
# the login-session map (env var scrubbed, kernel session id inherited).
sess_home="$test_tmp_dir/sess-home"
sess_audit="$test_tmp_dir/sess-audit"
sess_dir="$test_tmp_dir/sess-map"
mkdir -p "$sess_home" "$sess_audit" "$sess_dir"; chmod 1733 "$sess_dir"
env -i PATH="$PATH" HOME="$sess_home" RT="$runtime_dir" \
	ADIR="$sess_audit" SDIR="$sess_dir" bash --noprofile --norc -c '
	set -u
	function dotfiles_dbg { :; }
	source "$RT/functions.internal.d/00-common.bash"
	source "$RT/functions.internal.d/10-history.bash"
	export DOTFILES_AUDIT_DIR="$ADIR" DOTFILES_AUDIT_SESSION_DIR="$SDIR" \
		DOTFILES_FEATURE_TRACK_COMMAND_DURATION=false
	# login shell: key set the identity, audit session 4242
	export DOTFILES_AUDIT_SESSION_ID=4242 BASH_HISTORY_USERNAME=alice
	[ "$(__dotfiles_audit_identity)" = alice ] || exit 10
	[ "$(cat "$SDIR/4242")" = alice ] || exit 11
	[ "$(stat -c %a "$SDIR/4242")" = 600 ] || exit 12
	# sudo su - : env scrubbed, SAME session id, now (pretend) root
	unset BASH_HISTORY_USERNAME
	[ "$(__dotfiles_audit_identity)" = alice ] || exit 13
	# unseeded / no-session must fall back, never mis-attribute
	export DOTFILES_AUDIT_SESSION_ID=4294967295
	[ "$(__dotfiles_audit_identity)" = "$(id -un)" ] || exit 14
	[ ! -e "$SDIR/4294967295" ] || exit 15
	export DOTFILES_AUDIT_SESSION_ID=7777
	[ "$(__dotfiles_audit_identity)" = "$(id -un)" ] || exit 16
	# password login (no key anywhere): the account seeds the session, so a
	# later `sudo su` shell of the same session records the login account
	[ "$(cat "$SDIR/7777")" = "$(id -un)" ] || exit 19
	# ...but an account seed never overwrites an entry already present
	printf "%s\n" "not a valid identity!" > "$SDIR/7779"
	export DOTFILES_AUDIT_SESSION_ID=7779
	[ "$(__dotfiles_audit_identity)" = "$(id -un)" ] || exit 20
	[ "$(cat "$SDIR/7779")" = "not a valid identity!" ] || exit 21
	# escalated append lands in alices file AND body, not root
	export DOTFILES_AUDIT_SESSION_ID=4242
	unset __dotfiles_audit_file_cached; audit_history_file_path > /dev/null
	AF="$(audit_history_file_path)"
	[ "$AF" = "$ADIR/alice.log" ] || exit 17
	history -c; history -s "id"; last_cmd_exit_code=0; append_bash_history_audit
	grep -q "alice .* id$" "$AF" || exit 18
' || fail "login-session identity recovery failed (exit $?)"
pass 'SSH-key identity survives su -/sudo su - via the login-session map'

#!SECTION audit unit behavior
audit_dir="$test_tmp_dir/audit"
audit_home="$test_tmp_dir/audit-home"
mkdir -p "$audit_dir" "$audit_home"
env -i PATH="$PATH" HOME="$audit_home" RT="$runtime_dir" ADIR="$audit_dir" bash --noprofile --norc -c '
	set -u
	function dotfiles_dbg { :; }
	source "$RT/functions.internal.d/00-common.bash"
	source "$RT/functions.internal.d/10-history.bash"
	# path resolution
	unset __dotfiles_audit_file_cached __dotfiles_agent_audit_file_cached
	export DOTFILES_AUDIT_DIR="$ADIR"
	[ "$(audit_history_file_path)" = "$ADIR/$(id -un).log" ] || exit 10
	unset __dotfiles_audit_file_cached; export BASH_HISTORY_USERNAME=alice
	[ "$(audit_history_file_path)" = "$ADIR/alice.log" ] || exit 11
	unset __dotfiles_audit_file_cached; export BASH_HISTORY_USERNAME="../evil"
	[ "$(audit_history_file_path)" = "$ADIR/$(id -un).log" ] || exit 12
	unset __dotfiles_audit_file_cached BASH_HISTORY_USERNAME
	export DOTFILES_AUDIT_DIR="$ADIR/nonexistent"
	[ "$(audit_history_file_path)" = "$HOME/.bash_history_audit" ] || exit 13
	export DOTFILES_AUDIT_DIR="$ADIR"
	unset __dotfiles_audit_file_cached
	unset __dotfiles_audit_file_cached
	export DOTFILES_AUDIT_FILE="$ADIR/override.log"
	[ "$(audit_history_file_path)" = "$ADIR/override.log" ] || exit 14
	unset __dotfiles_audit_file_cached DOTFILES_AUDIT_FILE
	unset __dotfiles_agent_audit_file_cached
	[ "$(agent_audit_history_file_path)" = "$ADIR/$(id -un).agent.log" ] || exit 15
	# an identity that names ANOTHER local account records under this account
	other_acct="$(id -un nobody 2> /dev/null || true)"
	if [ -n "$other_acct" ] && [ "$other_acct" != "$(id -un)" ]; then
		unset __dotfiles_audit_file_cached; export BASH_HISTORY_USERNAME="$other_acct"
		[ "$(audit_history_file_path)" = "$ADIR/$(id -un).log" ] || exit 17
		unset BASH_HISTORY_USERNAME
	fi
	# HISTFILE decoupling
	unset __dotfiles_audit_file_cached
	HISTFILE="$HOME/elsewhere/.bash_history"
	[ "$(audit_history_file_path)" = "$ADIR/$(id -un).log" ] || exit 16
	unset HISTFILE
	# append / dedupe / replace
	export BASH_HISTORY_USERNAME=bob DOTFILES_FEATURE_TRACK_COMMAND_DURATION=false
	unset __dotfiles_audit_file_cached
	audit_history_file_path > /dev/null
	AF="$(audit_history_file_path)"
	history -c
	history -s "echo one"; last_cmd_exit_code=0; append_bash_history_audit
	[ "$(wc -l < "$AF")" = 1 ] || exit 20
	grep -q "took:-" "$AF" || exit 21
	append_bash_history_audit
	[ "$(wc -l < "$AF")" = 1 ] || exit 22
	history -s "echo one"; last_cmd_exit_code=0; append_bash_history_audit
	[ "$(wc -l < "$AF")" = 1 ] || exit 23
	history -s "echo one"; last_cmd_exit_code=7; append_bash_history_audit
	[ "$(wc -l < "$AF")" = 2 ] || exit 24
	grep -q "exit:7" "$AF" || exit 25
	# duplicate re-run via simulated DEBUG capture (same event, fresh capture)
	__dotfiles_audit_capture_seen=1; __dotfiles_audit_captured_cmd="echo one"
	last_cmd_exit_code=7; append_bash_history_audit
	[ "$(wc -l < "$AF")" = 2 ] || exit 26
	[ "$__dotfiles_audit_capture_seen" = 0 ] || exit 27
	# space-prefixed opt-out: capture differs from last history entry
	__dotfiles_audit_capture_seen=1; __dotfiles_audit_captured_cmd=" secret-cmd"
	append_bash_history_audit
	[ "$(wc -l < "$AF")" = 2 ] || exit 28
	! grep -q "secret-cmd" "$AF" || exit 29
	# username truncation
	export BASH_HISTORY_USERNAME="very-long-username-that-exceeds-24-chars"
	history -s "echo two"; last_cmd_exit_code=0
	unset __dotfiles_audit_file_cached; audit_history_file_path > /dev/null
	AF2="$(audit_history_file_path)"
	append_bash_history_audit
	ucol="$(tail -1 "$AF2" | awk "{print \$2}")"
	[ "${#ucol}" -le 24 ] || exit 30
	[[ "$ucol" == *... ]] || exit 31
	[ "$(stat -c %a "$AF")" = 600 ] || exit 32
' || fail "audit unit behavior failed (exit $?)"
pass 'audit paths, dedupe, replace-last-line, capture, and truncation behave'

# [regression] sticky shared store + fs.protected_regular: a file owned by
# another user cannot be appended to, root included. Needs a second uid, so
# this block runs only when the suite itself runs as root.
if [ "$(id -u)" -eq 0 ] && id -u nobody > /dev/null 2>&1; then
	sticky_dir="$test_tmp_dir/sticky-audit"
	mkdir -p "$sticky_dir"; chmod 1733 "$sticky_dir"
	: > "$sticky_dir/root.log"; chown nobody "$sticky_dir/root.log"; chmod 600 "$sticky_dir/root.log"
	: > "$sticky_dir/nobody.log"; chown nobody "$sticky_dir/nobody.log"; chmod 600 "$sticky_dir/nobody.log"
	env -i PATH="$PATH" HOME="$audit_home" RT="$runtime_dir" ADIR="$sticky_dir" bash --noprofile --norc -c '
		set -u
		function dotfiles_dbg { :; }
		source "$RT/functions.internal.d/00-common.bash"
		source "$RT/functions.internal.d/10-history.bash"
		export DOTFILES_AUDIT_DIR="$ADIR" DOTFILES_FEATURE_TRACK_COMMAND_DURATION=false
		# sudo su from "nobody": identity names a local account -> root.log,
		# and the file an older runtime handed to SUDO_USER is reclaimed
		export BASH_HISTORY_USERNAME=nobody
		unset __dotfiles_audit_file_cached
		[ "$(audit_history_file_path)" = "$ADIR/root.log" ] || exit 40
		[ "$(stat -c %U "$ADIR/root.log")" = root ] || exit 41
		history -c; history -s "id"; last_cmd_exit_code=0; append_bash_history_audit
		grep -q "nobody .* id$" "$ADIR/root.log" || exit 42
		[ "$(stat -c %U "$ADIR/nobody.log")" = nobody ] || exit 43
		[ ! -s "$ADIR/nobody.log" ] || exit 44
	' || fail "sticky-store ownership handling failed (exit $?)"
	pass 'root after sudo su records under root.log and reclaims a handed-over file'
fi

#!SECTION audit end-to-end (interactive)
e2e_audit_home="$test_tmp_dir/e2e-audit-home"
e2e_audit_dir="$test_tmp_dir/e2e-audit"
mkdir -p "$e2e_audit_home" "$e2e_audit_dir"
cp "$repo_dir/.bash_profile" "$repo_dir/.bashrc" "$e2e_audit_home/"
env -i PATH="$PATH" HOME="$e2e_audit_home" TERM=dumb DOTFILES_HOME="$runtime_dir" \
	DOTFILES_AUDIT_DIR="$e2e_audit_dir" BASH_HISTORY_USERNAME=e2euser \
	bash --noprofile --norc -i <<'AUDIT_EOF' > /dev/null 2>&1
source ~/.bash_profile
ls /nonexistent-dup-test
ls /nonexistent-dup-test
ls /nonexistent-dup-test
 export SECRET=hunter2
echo done
AUDIT_EOF
audit_log="$e2e_audit_dir/e2euser.log"
[ -s "$audit_log" ] || fail 'interactive audit produced no records'
[ "$(grep -c 'ls /nonexistent-dup-test' "$audit_log")" = 1 ] \
	|| fail 'consecutive duplicate re-runs were not collapsed in place'
grep -q 'exit:2 .*ls /nonexistent-dup-test' "$audit_log" \
	|| fail 'duplicate re-run did not keep its exit code'
! grep -q 'SECRET\|hunter2' "$audit_log" || fail 'space-prefixed command leaked into the audit'
grep -q 'echo done' "$audit_log" || fail 'ordinary command missing from the audit'
pass 'interactive minimal-profile audit records, collapses duplicates, honors the space opt-out'

# [regression] A new interactive login must NOT re-audit the previous session's
# last command (inherited via HISTFILE). The first PROMPT_COMMAND cycle runs
# before the user types anything, so its `history 1` is the prior session's last
# entry; recording it fabricated a phantom line (fresh timestamp, exit:0) at
# every login.
reaudit_home="$test_tmp_dir/reaudit-home"
reaudit_audit="$test_tmp_dir/reaudit-audit"
mkdir -p "$reaudit_home" "$reaudit_audit"
cp "$repo_dir/.bash_profile" "$repo_dir/.bashrc" "$reaudit_home/"
env -i PATH="$PATH" HOME="$reaudit_home" TERM=dumb DOTFILES_HOME="$runtime_dir" \
	DOTFILES_AUDIT_DIR="$reaudit_audit" BASH_HISTORY_USERNAME=ruser \
	bash --noprofile --norc -i > /dev/null 2>&1 <<'S1'
source ~/.bash_profile
echo session-one-cmd
S1
env -i PATH="$PATH" HOME="$reaudit_home" TERM=dumb DOTFILES_HOME="$runtime_dir" \
	DOTFILES_AUDIT_DIR="$reaudit_audit" BASH_HISTORY_USERNAME=ruser \
	bash --noprofile --norc -i > /dev/null 2>&1 <<'S2'
source ~/.bash_profile
echo session-two-cmd
S2
reaudit_log="$reaudit_audit/ruser.log"
[ -s "$reaudit_log" ] || fail 'first-prompt re-audit test produced no records'
[ "$(grep -c 'echo session-one-cmd' "$reaudit_log")" = 1 ] \
	|| fail "previous session's last command was re-audited at the next login (phantom record)"
grep -q 'echo session-two-cmd' "$reaudit_log" \
	|| fail 'second session command missing from the audit'
pass 'a new login does not re-audit the previous session inherited last command'

#!SECTION viewer
env -i PATH="$PATH" HOME="$e2e_audit_home" DOTFILES_HOME="$runtime_dir" \
	DOTFILES_AUDIT_DIR="$e2e_audit_dir" bash --noprofile --norc -c '
	function dotfiles_dbg { :; }
	export DOTFILES_FEATURE_PROMPT_HOOKS=false DOTFILES_FEATURE_HISTORY_AUDIT=false \
		DOTFILES_FEATURE_TRACK_COMMAND_DURATION=false DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK=false
	source "$DOTFILES_HOME/functions" > /dev/null 2>&1
	__dotfiles_audit_sudo() { case "${1:-}" in -n|-v) return 0;; esac; "$@"; }
	printf "0001-01-01T00:00:00+0000  zz  exit:0    took:-     first\n" > "$DOTFILES_AUDIT_DIR/aaa.log"
	printf "agent-line\n" > "$DOTFILES_AUDIT_DIR/bbb.agent.log"
	merged="$(audit_bash_history --all)"
	[[ "$merged" == *first* ]] || exit 1
	[[ "$merged" == *e2euser* || "$merged" == *"echo done"* ]] || exit 2
	[[ "$merged" != *agent-line* ]] || exit 3
	agent_merged="$(audit_bash_history -a -A)"
	[[ "$agent_merged" == *agent-line* ]] || exit 4
	[[ "$agent_merged" != *first* ]] || exit 5
	limited="$(audit_bash_history --all 2 | wc -l)"
	[ "$limited" = 2 ] || exit 6
	DOTFILES_AUDIT_DIR="$DOTFILES_AUDIT_DIR/missing" audit_bash_history --all > /dev/null 2>&1 && exit 7
	exit 0
' || fail "viewer merged view failed (exit $?)"
pass 'audit_bash_history merges shared logs, separates agent logs, degrades gracefully'

#!SECTION bootstrap: system scope
system_fixture="$test_tmp_dir/system-install"
system_root="$system_fixture/usr/local/share/dotfiles"
system_profile_d="$system_fixture/etc/profile.d"
system_audit="$system_fixture/var/log/dotfiles/audit"
system_home="$system_fixture/home"
mkdir -p "$system_profile_d" "$system_home"
HOME="$system_home" \
	DOTFILES_BOOTSTRAP_NO_SUDO=true \
	DOTFILES_BOOTSTRAP_SKIP_COMPLETION=true \
	DOTFILES_SYSTEM_INSTALL_ROOT="$system_root" \
	DOTFILES_SYSTEM_PROFILE_D_DIR="$system_profile_d" \
	DOTFILES_SYSTEM_AUDIT_DIR="$system_audit" \
	DOTFILES_SYSTEM_SESSION_DIR="$system_fixture/run/sessions" \
	bash "$repo_dir/bootstrap.sh" --force > /dev/null \
	|| fail 'default system-wide bootstrap failed'
[ -r "$system_root/functions" ] || fail 'system install omitted the runtime loader'
[ -r "$system_root/bash_profile" ] || fail 'system install omitted the runtime bash_profile'
[ -r "$system_root/init/claude-code-audit-hook.sh" ] || fail 'system install omitted init/'
[ -r "$system_profile_d/dotfiles.sh" ] || fail 'system install omitted the profile.d hook'
grep -q '^scope=system$' "$system_root/.dotfiles-install" \
	|| fail 'system install metadata has the wrong scope'
[ "$(stat -c '%a' "$system_audit")" = 1733 ] || fail 'audit dir does not have mode 1733'
[ "$(stat -c '%a' "$system_fixture/run/sessions" 2> /dev/null)" = 1733 ] \
	|| fail 'login-session map dir was not created with mode 1733'
! grep -q 'case "\$-"' "$system_profile_d/dotfiles.sh" \
	|| fail 'profile.d hook regained an interactivity guard (breaks agent shells)'
pass 'bootstrap defaults to a system-wide install with hook, metadata, audit store'

# The decisive regression test: non-interactive login shells (agents) must get
# the runtime + guard through the hook.
env -i PATH="$PATH" HOME="$system_home" TERM=dumb CLAUDECODE=1 bash --noprofile --norc -c '
	. "$1"
	[ "$DOTFILES_AGENT" = claude-code ] || exit 1
	[ "$DOTFILES_INSTALL_SCOPE" = system ] || exit 1
	[ -z "${PROMPT_COMMAND:-}" ] || exit 1
	! declare -F dotfiles_update >/dev/null || exit 1
' _ "$system_profile_d/dotfiles.sh" || fail 'hook did not activate agent mode for a non-interactive shell'
env -i PATH="$PATH" HOME="$system_home" TERM=dumb bash --noprofile --norc -i -c '
	. "$1"
	[ "$DOTFILES_HOME" != "$HOME" ] || exit 1
	[ "$DOTFILES_INSTALL_SCOPE" = system ] || exit 1
	[ "$DOTFILES_FEATURE_PROFILE" = minimal ] || exit 1
	declare -F dotfiles_update >/dev/null || exit 1
	alias gst >/dev/null 2>&1 || exit 1
' _ "$system_profile_d/dotfiles.sh" > /dev/null 2>&1 \
	|| fail 'profile.d hook did not activate the shared runtime interactively'
pass 'profile.d hook serves agent (non-interactive) and interactive shells alike'

#!SECTION bootstrap: migrate-user safety
migration_home="$system_fixture/migration-home"
mkdir -p "$migration_home/.config/dotfiles"
printf '%s\n' '# Executing .BASH_PROFILE legacy marker' > "$migration_home/.bash_profile"
printf '%s\n' '# distro default, definitely not ours' > "$migration_home/.bashrc"
printf '%s\n' '# legacy runtime loader' > "$migration_home/.functions"
printf '%s\n' 'export PATH="$HOME/bin:$PATH"' > "$migration_home/.path"
printf 'DOTFILES_FEATURE_PROFILE=full\n' > "$migration_home/.config/dotfiles/features.local"
HOME="$migration_home" \
	DOTFILES_LOCAL_HOME="$migration_home/.config/dotfiles" \
	DOTFILES_BOOTSTRAP_NO_SUDO=true \
	DOTFILES_BOOTSTRAP_SKIP_COMPLETION=true \
	DOTFILES_SYSTEM_INSTALL_ROOT="$system_root" \
	DOTFILES_SYSTEM_PROFILE_D_DIR="$system_profile_d" \
	DOTFILES_SYSTEM_AUDIT_DIR="$system_audit" \
	DOTFILES_SYSTEM_SESSION_DIR="$system_fixture/run/sessions" \
	bash "$repo_dir/bootstrap.sh" --system --migrate-user --force > /dev/null \
	|| fail 'legacy per-user migration failed'
compgen -G "$migration_home/.dotfiles-user-install-backup-*/.bash_profile" > /dev/null \
	|| fail 'migration did not back up the legacy profile'
grep -q 'definitely not ours' "$migration_home/.bashrc" \
	|| fail 'migration touched a distro-owned ~/.bashrc'
[ ! -e "$migration_home/.path" ] || fail 'legacy ~/.path was not absorbed (it is retired by design)'
grep -q 'HOME/bin' "$migration_home/.systemspecific" \
	|| fail '~/.path content did not survive into ~/.systemspecific'
[ -r "$migration_home/.config/dotfiles/features.local" ] \
	|| fail 'migration removed a per-user features.local'
pass 'system bootstrap backs up only dotfiles-owned files and spares user rc/overrides'

# The per-user audit trail follows the migration into the shared store,
# merged by timestamp with records the new runtime may already have written.
audit_merge_home="$system_fixture/audit-merge-home"
mkdir -p "$audit_merge_home"
printf '%s\n' '# Executing .BASH_PROFILE legacy marker' > "$audit_merge_home/.bash_profile"
printf '%s\n' '# legacy runtime loader' > "$audit_merge_home/.functions"
audit_rec='%-24s  %-24s  exit:%-3s  took:%-9s  %s\n'
printf "$audit_rec" 2026-01-01T10:00:00+0100 me 0 - 'old one' > "$audit_merge_home/.bash_history_audit"
printf "$audit_rec" 2026-01-03T10:00:00+0100 me 0 - 'old three' >> "$audit_merge_home/.bash_history_audit"
printf "$audit_rec" 2026-01-02T10:00:00+0100 me 0 - 'new two' > "$system_audit/$(id -un).log"
chmod 600 "$system_audit/$(id -un).log"
HOME="$audit_merge_home" \
	DOTFILES_BOOTSTRAP_NO_SUDO=true \
	DOTFILES_BOOTSTRAP_SKIP_COMPLETION=true \
	DOTFILES_SYSTEM_INSTALL_ROOT="$system_root" \
	DOTFILES_SYSTEM_PROFILE_D_DIR="$system_profile_d" \
	DOTFILES_SYSTEM_AUDIT_DIR="$system_audit" \
	DOTFILES_SYSTEM_SESSION_DIR="$system_fixture/run/sessions" \
	bash "$repo_dir/bootstrap.sh" --system --migrate-user --force > /dev/null \
	|| fail 'migration with a legacy audit trail failed'
merged_log="$system_audit/$(id -un).log"
[ "$(wc -l < "$merged_log")" = 3 ] || fail 'legacy audit records were not merged into the shared store'
[ "$(awk '{print $NF}' "$merged_log" | tr '\n' ' ')" = 'one two three ' ] \
	|| fail 'merged audit records are not in timestamp order'
[ "$(stat -c %a "$merged_log")" = 600 ] || fail 'merged audit file is not mode 0600'
[ ! -e "$audit_merge_home/.bash_history_audit" ] || fail 'legacy audit file was left behind after the merge'
compgen -G "$audit_merge_home/.dotfiles-user-install-backup-*/.bash_history_audit" > /dev/null \
	|| fail 'legacy audit file was not parked in the backup dir'
rm -f "$merged_log"
pass 'migration merges the legacy audit trail into the shared store by timestamp'

bash "$repo_dir/bootstrap.sh" --user --migrate-user > /dev/null 2>&1
[ "$?" = 2 ] || fail '--migrate-user with --user did not error with exit 2'
pass '--migrate-user with --user is rejected'

# SUDO_USER in the environment must NOT redirect the migration when the
# bootstrap is not actually running as root (only sudo-root runs re-target).
sudo_env_home="$system_fixture/sudo-env-home"
mkdir -p "$sudo_env_home"
printf '%s\n' '# Executing .BASH_PROFILE legacy marker' > "$sudo_env_home/.bash_profile"
printf '%s\n' '# legacy runtime loader' > "$sudo_env_home/.functions"
HOME="$sudo_env_home" \
	SUDO_USER=root \
	DOTFILES_BOOTSTRAP_NO_SUDO=true \
	DOTFILES_BOOTSTRAP_SKIP_COMPLETION=true \
	DOTFILES_SYSTEM_INSTALL_ROOT="$system_root" \
	DOTFILES_SYSTEM_PROFILE_D_DIR="$system_profile_d" \
	DOTFILES_SYSTEM_AUDIT_DIR="$system_audit" \
	DOTFILES_SYSTEM_SESSION_DIR="$system_fixture/run/sessions" \
	bash "$repo_dir/bootstrap.sh" --system --migrate-user --force > /dev/null \
	|| fail 'migration with stray SUDO_USER failed'
compgen -G "$sudo_env_home/.dotfiles-user-install-backup-*/.bash_profile" > /dev/null \
	|| fail 'stray SUDO_USER redirected the migration away from $HOME'
pass 'migration ignores SUDO_USER unless actually running as root'

# Installs from the pre-2026-08-31 layout carry a copy-pasted "Executing
# .BASHRC" marker in ~/.bash_profile (no DOTFILES_HOME line either); the
# detector must still recognise them as dotfiles-owned.
old_marker_home="$system_fixture/old-marker-home"
mkdir -p "$old_marker_home"
printf '%s\n' '[[ $DOTFILES_DEBUG == "true" ]] && echo "[DOTFILE_DBG: Executing .BASHRC]"' > "$old_marker_home/.bash_profile"
printf '%s\n' '# legacy runtime loader' > "$old_marker_home/.functions"
HOME="$old_marker_home" \
	DOTFILES_BOOTSTRAP_NO_SUDO=true \
	DOTFILES_BOOTSTRAP_SKIP_COMPLETION=true \
	DOTFILES_SYSTEM_INSTALL_ROOT="$system_root" \
	DOTFILES_SYSTEM_PROFILE_D_DIR="$system_profile_d" \
	DOTFILES_SYSTEM_AUDIT_DIR="$system_audit" \
	DOTFILES_SYSTEM_SESSION_DIR="$system_fixture/run/sessions" \
	bash "$repo_dir/bootstrap.sh" --system --migrate-user --force > /dev/null \
	|| fail 'migration of an old-marker per-user install failed'
compgen -G "$old_marker_home/.dotfiles-user-install-backup-*/.bash_profile" > /dev/null \
	|| fail 'old "Executing .BASHRC" marker was not recognised as dotfiles-owned'
[ ! -e "$old_marker_home/.functions" ] \
	|| fail 'old-marker migration left ~/.functions in place'
pass 'migration recognises the pre-2026-08-31 .BASHRC marker in ~/.bash_profile'

# dotfiles_profile must create $DOTFILES_LOCAL_HOME on demand: system-scope
# installs never create it, and the first `dotfiles_profile full` used to fail.
profile_home="$system_fixture/profile-home"
mkdir -p "$profile_home"
env -i HOME="$profile_home" PATH="$PATH" bash -c '
	dotfiles_dbg() { :; }
	. "$1/.config/dotfiles/functions.external.d/20-dotfiles.bash"
	dotfiles_profile full > /dev/null || exit 1
	grep -qx "DOTFILES_FEATURE_PROFILE=full" "$HOME/.config/dotfiles/features.local" || exit 1
	dotfiles_profile light > /dev/null || exit 1
	[ "$(grep -c "^DOTFILES_FEATURE_PROFILE=" "$HOME/.config/dotfiles/features.local")" = 1 ] || exit 1
	dotfiles_profile reset > /dev/null || exit 1
	! grep -q "^DOTFILES_FEATURE_PROFILE=" "$HOME/.config/dotfiles/features.local"
' _ "$repo_dir" \
	|| fail 'dotfiles_profile did not create the local override dir or mis-edited features.local'
pass 'dotfiles_profile creates ~/.config/dotfiles on demand and edits the override idempotently'

#!SECTION bootstrap: user scope + legacy layouts
user_fixture="$test_tmp_dir/user-install"
mkdir -p "$user_fixture/.functions.internal.d" "$user_fixture/.aliases/bash"
# A real dotted-layout install always carries a dotfiles-managed ~/.bash_profile;
# migrate_legacy_layout only reclaims collision-prone dotted names when it sees
# that marker (see the fresh-user test below).
printf '%s\n' '# dotfiles' 'dotfiles_dbg "Executing .BASH_PROFILE"' > "$user_fixture/.bash_profile"
printf '%s\n' '# legacy module' > "$user_fixture/.functions.internal.d/00-common.bash"
printf '%s\n' '# legacy loader' > "$user_fixture/.functions"
printf 'DOTFILES_FEATURE_PROFILE=light\n' > "$user_fixture/.dotfiles_features.local"
HOME="$user_fixture" \
	DOTFILES_HOME="$user_fixture/.config/dotfiles" \
	DOTFILES_LOCAL_HOME="$user_fixture/.config/dotfiles" \
	DOTFILES_BOOTSTRAP_NO_SOURCE_PROFILE=true \
	DOTFILES_BOOTSTRAP_SKIP_COMPLETION=true \
	DOTFILES_BOOTSTRAP_NO_SUDO=true \
	bash "$repo_dir/bootstrap.sh" --user --force > /dev/null \
	|| fail 'explicit per-user bootstrap failed'
grep -q '^scope=user$' "$user_fixture/.config/dotfiles/.dotfiles-install" \
	|| fail 'per-user install metadata has the wrong scope'
[ -r "$user_fixture/.config/dotfiles/functions.external.d/20-dotfiles.bash" ] \
	|| fail 'per-user install omitted runtime modules'
[ ! -e "$user_fixture/.functions.internal.d" ] || fail 'dotted module layout survived migration'
[ ! -e "$user_fixture/.functions" ] || fail 'legacy loader survived migration'
[ "$(cat "$user_fixture/.config/dotfiles/features.local")" = 'DOTFILES_FEATURE_PROFILE=light' ] \
	|| fail 'legacy features.local was not relocated'
grep -q '_DOTFILES_RUNTIME_LOADED' "$user_fixture/.bash_profile" \
	|| fail 'per-user install did not place the stub profile'
pass 'per-user install migrates legacy layouts and lands the stub + runtime'

# [regression] A first-time user with no prior dotfiles install but their own
# personal ~/.exports / ~/.functions must NOT have them silently deleted.
fresh_fixture="$test_tmp_dir/fresh-user"
mkdir -p "$fresh_fixture"
printf 'export EDITOR=vim\n' > "$fresh_fixture/.exports"
printf 'myfunc() { echo hi; }\n' > "$fresh_fixture/.functions"
printf '# my prompt\n' > "$fresh_fixture/.bash_prompt"
HOME="$fresh_fixture" \
	DOTFILES_HOME="$fresh_fixture/.config/dotfiles" \
	DOTFILES_LOCAL_HOME="$fresh_fixture/.config/dotfiles" \
	DOTFILES_BOOTSTRAP_NO_SOURCE_PROFILE=true \
	DOTFILES_BOOTSTRAP_SKIP_COMPLETION=true \
	DOTFILES_BOOTSTRAP_NO_SUDO=true \
	bash "$repo_dir/bootstrap.sh" --user --force > /dev/null \
	|| fail 'fresh-user per-user bootstrap failed'
[ "$(cat "$fresh_fixture/.exports")" = 'export EDITOR=vim' ] \
	|| fail 'fresh user personal ~/.exports was destroyed by --user install'
grep -q 'myfunc' "$fresh_fixture/.functions" \
	|| fail 'fresh user personal ~/.functions was destroyed by --user install'
[ -e "$fresh_fixture/.bash_prompt" ] \
	|| fail 'fresh user personal ~/.bash_prompt was destroyed by --user install'
pass 'a fresh user own dotfiles survive a --user install (no legacy marker)'

#!SECTION update mechanism
update_fixture="$test_tmp_dir/update-state"
mkdir -p "$update_fixture/cache"
printf '%s\n' \
	'scope=system' \
	'install_root=/tmp/shared-dotfiles' \
	'source_url=https://example.invalid/dotfiles.git' \
	'source_branch=main' \
	'installed_commit=abc123' \
	'update_mode=remote' \
	'installed_at=1' > "$update_fixture/install"
DOTFILES_INSTALL_METADATA_FILE="$update_fixture/install" TEST_CACHE="$update_fixture/cache" \
	bash --noprofile --norc -c '
		export DOTFILES_DEBUG=false
		export DOTFILES_FEATURE_TRACK_COMMAND_DURATION=false
		export DOTFILES_FEATURE_PROMPT_HOOKS=false
		export DOTFILES_FEATURE_HISTORY_AUDIT=false
		export DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK=false
		source "$1/functions"
		__dotfiles_update_state_dir="$TEST_CACHE"
		__dotfiles_update_state_file="$TEST_CACHE/update_state"
		__dotfiles_update_check_lock_dir="$TEST_CACHE/update_check.lock"
		function git {
			[ "$1" = ls-remote ] && printf "abc123\trefs/heads/main\n"
		}
		__dotfiles_run_update_check_worker
		grep -q "^status=up_to_date$" "$__dotfiles_update_state_file"
		__dotfiles_write_update_state update_available old456 abc123 1 ""
		function __dotfiles_should_auto_check_updates { return 0; }
		[ -z "$(__dotfiles_maybe_show_update_notice_once)" ]
		grep -q "^status=unknown$" "$__dotfiles_update_state_file"
		grep -q "^local_commit=abc123$" "$__dotfiles_update_state_file"
	' _ "$runtime_dir" || fail 'installed-version update state handling failed'
pass 'update state follows the installed commit and invalidates stale notices'

sed 's/^update_mode=remote$/update_mode=manual/' "$update_fixture/install" > "$update_fixture/manual-install"
if manual_update_error="$(
	DOTFILES_INSTALL_METADATA_FILE="$update_fixture/manual-install" \
	bash --noprofile --norc -c '
		export DOTFILES_DEBUG=false
		export DOTFILES_FEATURE_TRACK_COMMAND_DURATION=false
		export DOTFILES_FEATURE_PROMPT_HOOKS=false
		export DOTFILES_FEATURE_HISTORY_AUDIT=false
		export DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK=false
		source "$1/functions"
		dotfiles_update
	' _ "$runtime_dir" 2>&1
)"; then
	fail 'dotfiles_update replaced a manual installation without explicit consent'
fi
[[ "$manual_update_error" == *'dotfiles_update --remote'* ]] \
	|| fail 'manual update refusal did not explain the explicit override'
pass 'manual installations cannot be replaced accidentally by dotfiles_update'

#!SECTION update end-to-end (offline)
update_e2e="$test_tmp_dir/update-e2e"
update_source="$update_e2e/source"
update_remote="$update_e2e/remote.git"
update_root="$update_e2e/shared"
update_profile_d="$update_e2e/profile.d"
update_audit="$update_e2e/audit"
update_home="$update_e2e/home"
mkdir -p "$update_source" "$update_profile_d" "$update_home"
rsync -a --exclude '.git/' "$repo_dir/" "$update_source/"
git -C "$update_source" init -q -b main
git -C "$update_source" config user.name 'Runtime Test'
git -C "$update_source" config user.email 'runtime@example.invalid'
git -C "$update_source" add -A
git -C "$update_source" commit -qm 'runtime v1'
git clone -q --bare "$update_source" "$update_remote"
git -C "$update_source" remote add origin "file://$update_remote"
git -C "$update_source" fetch -q origin
git -C "$update_source" remote set-head origin main
update_commit_one="$(git -C "$update_source" rev-parse HEAD)"
HOME="$update_home" \
	DOTFILES_BOOTSTRAP_NO_SUDO=true \
	DOTFILES_BOOTSTRAP_SKIP_COMPLETION=true \
	DOTFILES_SYSTEM_INSTALL_ROOT="$update_root" \
	DOTFILES_SYSTEM_PROFILE_D_DIR="$update_profile_d" \
	DOTFILES_SYSTEM_AUDIT_DIR="$update_audit" \
	DOTFILES_SYSTEM_SESSION_DIR="$update_e2e/run/sessions" \
	bash "$update_source/bootstrap.sh" --system --force > /dev/null \
	|| fail 'initial end-to-end system installation failed'
grep -q "^installed_commit=$update_commit_one$" "$update_root/.dotfiles-install" \
	|| fail 'initial end-to-end install metadata does not match its commit'
git -C "$update_source" commit --allow-empty -qm 'runtime v2'
git -C "$update_source" push -q origin main
update_commit_two="$(git -C "$update_source" rev-parse HEAD)"
HOME="$update_home" \
	DOTFILES_HOME="$update_root" \
	DOTFILES_INSTALL_SCOPE=system \
	DOTFILES_AGENT_GUARD=false \
	DOTFILES_BOOTSTRAP_NO_SUDO=true \
	DOTFILES_SYSTEM_PROFILE_D_DIR="$update_profile_d" \
	DOTFILES_SYSTEM_AUDIT_DIR="$update_audit" \
	DOTFILES_SYSTEM_SESSION_DIR="$update_e2e/run/sessions" \
	DOTFILES_FEATURE_HISTORY_AUDIT=false \
	bash --noprofile --norc -c '
		source "$DOTFILES_HOME/bash_profile" >/dev/null 2>&1
		function reload { return 0; }
		dotfiles_update > /dev/null
	' || fail 'end-to-end dotfiles_update failed'
grep -q "^installed_commit=$update_commit_two$" "$update_root/.dotfiles-install" \
	|| fail 'updated install metadata does not match the remote commit'
grep -q '^status=up_to_date$' "$update_home/.cache/dotfiles/update_state" \
	|| fail 'dotfiles_update did not refresh the calling user cache'
pass 'system update moves the installed commit and cache to the remote version'

printf 'PASS: %d runtime checks completed\n' "$tests_run"
