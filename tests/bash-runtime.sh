#!/usr/bin/env bash

set -u

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

for shell_file in \
	"$repo_dir/.functions.internal.d/"*.bash \
	"$repo_dir/.functions.external.d/"*.bash; do
	bash -n "$shell_file" || fail "syntax check failed: $shell_file"
done
bash -n "$repo_dir/.functions" || fail "syntax check failed: .functions"
bash -n "$repo_dir/.functions.internal.bash" || fail "syntax check failed: .functions.internal.bash"
bash -n "$repo_dir/.functions.external.bash" || fail "syntax check failed: .functions.external.bash"
pass 'all runtime modules have valid Bash syntax'

export DOTFILES_FEATURE_TRACK_COMMAND_DURATION=false
export DOTFILES_FEATURE_PROMPT_HOOKS=false
export DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK=false
export DOTFILES_DEBUG=false
source "$repo_dir/.functions" || fail 'complete runtime failed to load'
for function_name in \
	check_for_dot_env do_my_checks dotfiles_update audit_bash_history \
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

runtime_copy="$test_tmp_dir/runtime"
mkdir -p "$runtime_copy"
cp "$repo_dir/.functions" "$repo_dir/.functions.internal.bash" \
	"$repo_dir/.functions.external.bash" "$runtime_copy/"
cp -R "$repo_dir/.functions.internal.d" "$repo_dir/.functions.external.d" "$runtime_copy/"
rm "$runtime_copy/.functions.internal.d/20-env.bash"
if loader_error="$(bash --noprofile --norc -c 'source "$1/.functions"' _ "$runtime_copy" 2>&1)"; then
	fail 'runtime load succeeded with a required module missing'
fi
[[ "$loader_error" == *'required internal module is missing or unreadable'* ]] \
	|| fail "missing-module error was not actionable (got: $loader_error)"
pass 'missing required modules fail with an actionable error'

profile_copy="$test_tmp_dir/profile"
mkdir -p "$profile_copy"
cp "$repo_dir/.bash_profile" "$profile_copy/"
if profile_error="$(HOME="$profile_copy" bash --noprofile --norc -c 'source "$HOME/.bash_profile"' 2>&1)"; then
	fail 'full profile load succeeded without the required .functions file'
fi
[[ "$profile_error" == *'required configuration file is missing or unreadable'* ]] \
	|| fail "missing .functions error was not actionable (got: $profile_error)"
pass 'full profile fails clearly when the runtime loader is missing'

HOME="$repo_dir" bash --noprofile --norc -c '
	source "$HOME/.bash_profile" >/dev/null
	declare -F dotfiles_update >/dev/null
	[ "$DOTFILES_FEATURE_PROFILE" = minimal ]
	[ "$DOTFILES_FEATURE_PROMPT_HOOKS" = false ]
	[ "$DOTFILES_FEATURE_AUTO_DOT_ENV" = false ]
	[ "$DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK" = false ]
' || fail 'full profile load failed'
pass 'default profile loads the conservative minimal feature set'

HOME="$repo_dir" BASH_SAFE_MODE=true bash --noprofile --norc -c '
	source "$HOME/.bash_profile" >/dev/null
	! declare -F dotfiles_update >/dev/null
	[ -z "${PROMPT_COMMAND:-}" ]
' || fail 'safe profile load failed or loaded full runtime state'
pass 'safe profile excludes the full runtime'

system_fixture="$test_tmp_dir/system-install"
system_root="$system_fixture/usr/local/share/dotfiles"
system_profile_d="$system_fixture/etc/profile.d"
system_home="$system_fixture/home"
mkdir -p "$system_profile_d" "$system_home"
HOME="$system_home" \
	DOTFILES_BOOTSTRAP_NO_SUDO=true \
	DOTFILES_BOOTSTRAP_SKIP_COMPLETION=true \
	DOTFILES_SYSTEM_INSTALL_ROOT="$system_root" \
	DOTFILES_SYSTEM_PROFILE_D_DIR="$system_profile_d" \
	bash "$repo_dir/bootstrap.sh" --force > /dev/null \
	|| fail 'default system-wide bootstrap failed'
[ -r "$system_root/.functions" ] || fail 'system install omitted the runtime loader'
[ -r "$system_profile_d/dotfiles.sh" ] || fail 'system install omitted the profile.d hook'
grep -q '^scope=system$' "$system_root/.dotfiles-install" \
	|| fail 'system install metadata has the wrong scope'
HOME="$system_home" DOTFILES_CONFIG_DIR="$system_root" DOTFILES_INSTALL_SCOPE=system \
	bash --noprofile --norc -c '
		source "$DOTFILES_CONFIG_DIR/.bash_profile" >/dev/null
		[ "$DOTFILES_FEATURE_PROFILE" = minimal ]
		[ "$DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK" = false ]
		declare -F dotfiles_update >/dev/null
		alias gst >/dev/null 2>&1
	' || fail 'installed shared runtime did not load correctly'
HOME="$system_home" DOTFILES_TEST_HOOK="$system_profile_d/dotfiles.sh" \
	bash --noprofile --norc -ic '
		. "$DOTFILES_TEST_HOOK"
		[ "$DOTFILES_CONFIG_DIR" != "$HOME" ]
		[ "$DOTFILES_INSTALL_SCOPE" = system ]
		[ "$DOTFILES_FEATURE_PROFILE" = minimal ]
		declare -F dotfiles_update >/dev/null
	' > /dev/null 2>&1 || fail 'profile.d hook did not activate the shared runtime'
pass 'bootstrap defaults to a loadable system-wide minimal installation'

migration_home="$system_fixture/migration-home"
mkdir -p "$migration_home"
printf '%s\n' '# Executing .BASH_PROFILE legacy marker' > "$migration_home/.bash_profile"
printf '%s\n' '# legacy runtime loader' > "$migration_home/.functions"
printf '%s\n' 'export PATH="$HOME/bin:$PATH"' > "$migration_home/.path"
HOME="$migration_home" \
	DOTFILES_BOOTSTRAP_NO_SUDO=true \
	DOTFILES_BOOTSTRAP_SKIP_COMPLETION=true \
	DOTFILES_SYSTEM_INSTALL_ROOT="$system_root" \
	DOTFILES_SYSTEM_PROFILE_D_DIR="$system_profile_d" \
	bash "$repo_dir/bootstrap.sh" --system --migrate-user --force > /dev/null \
	|| fail 'legacy per-user migration failed'
[ ! -e "$migration_home/.bash_profile" ] || fail 'legacy profile remained active after migration'
[ -r "$migration_home/.path" ] || fail 'migration removed a user-local override'
compgen -G "$migration_home/.dotfiles-user-install-backup-*/.bash_profile" > /dev/null \
	|| fail 'migration did not back up the legacy profile'
pass 'system bootstrap can safely back up and deactivate a legacy user install'

user_fixture="$test_tmp_dir/user-install"
mkdir -p "$user_fixture"
HOME="$user_fixture" \
	DOTFILES_BOOTSTRAP_NO_SOURCE_PROFILE=true \
	DOTFILES_BOOTSTRAP_SKIP_COMPLETION=true \
	bash "$repo_dir/bootstrap.sh" --user --force > /dev/null \
	|| fail 'explicit per-user bootstrap failed'
grep -q '^scope=user$' "$user_fixture/.dotfiles-install" \
	|| fail 'per-user install metadata has the wrong scope'
[ -r "$user_fixture/.functions.external.d/20-dotfiles.bash" ] \
	|| fail 'per-user install omitted runtime modules'
pass 'legacy per-user installation remains available explicitly'

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
		export DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK=false
		source "$1/.functions"
		__dotfiles_update_state_dir="$TEST_CACHE"
		__dotfiles_update_state_file="$TEST_CACHE/update_state"
		__dotfiles_update_check_lock_dir="$TEST_CACHE/update_check.lock"
		function git {
			[ "$1" = ls-remote ] && printf "abc123\\trefs/heads/main\\n"
		}
		__dotfiles_run_update_check_worker
		grep -q "^status=up_to_date$" "$__dotfiles_update_state_file"
		__dotfiles_write_update_state update_available old456 abc123 1 ""
		function __dotfiles_should_auto_check_updates { return 0; }
		[ -z "$(__dotfiles_maybe_show_update_notice_once)" ]
		grep -q "^status=unknown$" "$__dotfiles_update_state_file"
		grep -q "^local_commit=abc123$" "$__dotfiles_update_state_file"
	' _ "$repo_dir" || fail 'installed-version update state handling failed'
pass 'update state follows the installed commit and invalidates stale notices'

sed 's/^update_mode=remote$/update_mode=manual/' "$update_fixture/install" > "$update_fixture/manual-install"
if manual_update_error="$(
	DOTFILES_INSTALL_METADATA_FILE="$update_fixture/manual-install" \
	bash --noprofile --norc -c '
		export DOTFILES_DEBUG=false
		export DOTFILES_FEATURE_TRACK_COMMAND_DURATION=false
		export DOTFILES_FEATURE_PROMPT_HOOKS=false
		export DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK=false
		source "$1/.functions"
		dotfiles_update
	' _ "$repo_dir" 2>&1
)"; then
	fail 'dotfiles_update replaced a manual installation without explicit consent'
fi
[[ "$manual_update_error" == *'dotfiles_update --remote'* ]] \
	|| fail 'manual update refusal did not explain the explicit override'
pass 'manual installations cannot be replaced accidentally by dotfiles_update'

update_e2e="$test_tmp_dir/update-e2e"
update_source="$update_e2e/source"
update_remote="$update_e2e/remote.git"
update_root="$update_e2e/shared"
update_profile_d="$update_e2e/profile.d"
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
	bash "$update_source/bootstrap.sh" --system --force > /dev/null \
	|| fail 'initial end-to-end system installation failed'
grep -q "^installed_commit=$update_commit_one$" "$update_root/.dotfiles-install" \
	|| fail 'initial end-to-end install metadata does not match its commit'
git -C "$update_source" commit --allow-empty -qm 'runtime v2'
git -C "$update_source" push -q origin main
update_commit_two="$(git -C "$update_source" rev-parse HEAD)"
HOME="$update_home" \
	DOTFILES_CONFIG_DIR="$update_root" \
	DOTFILES_INSTALL_SCOPE=system \
	DOTFILES_BOOTSTRAP_NO_SUDO=true \
	DOTFILES_SYSTEM_PROFILE_D_DIR="$update_profile_d" \
	bash --noprofile --norc -c '
		source "$DOTFILES_CONFIG_DIR/.bash_profile" >/dev/null
		function reload { return 0; }
		dotfiles_update > /dev/null
	' || fail 'end-to-end dotfiles_update failed'
grep -q "^installed_commit=$update_commit_two$" "$update_root/.dotfiles-install" \
	|| fail 'updated install metadata does not match the remote commit'
grep -q '^status=up_to_date$' "$update_home/.cache/dotfiles/update_state" \
	|| fail 'dotfiles_update did not refresh the calling user cache'
pass 'system update moves the installed commit and cache to the remote version'

printf 'PASS: %d runtime checks completed\n' "$tests_run"
