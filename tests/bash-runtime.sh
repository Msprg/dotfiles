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
' || fail 'full profile load failed'
pass 'full profile loads successfully'

HOME="$repo_dir" BASH_SAFE_MODE=true bash --noprofile --norc -c '
	source "$HOME/.bash_profile" >/dev/null
	! declare -F dotfiles_update >/dev/null
	[ -z "${PROMPT_COMMAND:-}" ]
' || fail 'safe profile load failed or loaded full runtime state'
pass 'safe profile excludes the full runtime'

printf 'PASS: %d runtime checks completed\n' "$tests_run"
