# Dotfiles

Personal Bash-focused dotfiles with feature toggles for prompt behavior, command
timing, per-directory history, and `.env` auto-loading.

## Installation

Clone and install:

```bash
git clone https://github.com/msprg/dotfiles.git
cd dotfiles
source bootstrap.sh
```

Update existing install:

```bash
cd /path/to/dotfiles
source bootstrap.sh
```

Skip bootstrap confirmation:

```bash
set -- -f; source bootstrap.sh
```

What `bootstrap.sh` does:
- Runs `git pull origin main` from repo root.
- Rsyncs dotfiles into `$HOME`.
- Excludes `.git/`, `*.md`, `*.sh`, `*.disabled`, and a few other non-runtime files.
- Ensures a Bash completion loader is installed (best effort).

## Shell Load Order

Interactive shells enter via `.bashrc`, which sources `.bash_profile`.

Full mode load order:
`~/.path` -> `~/.dotfiles_features` -> `~/.bash_prompt` -> `~/.exports` -> `~/.functions` -> `~/.extra` -> `~/.systemspecific` -> `~/.aliases/bash/aliases`

Function file split:
- `~/.functions` is a loader.
- `~/.functions.internal.bash` contains internal dotfiles runtime hooks/helpers.
- `~/.functions.external.bash` contains user-facing interactive function definitions.

Safe mode (`BASH_SAFE_MODE=true`) loads only:
`~/.path` and `~/.exports`

In safe mode, prompt/functions/aliases/completions/PROMPT_COMMAND hooks are skipped.

## Runtime Controls

Quick shell reload helpers:
- `reload`: restart login shell in full mode.
- `safe_reload`: restart login shell in safe mode.
- `debug_reload`: restart login shell with `DOTFILES_DEBUG=true`.
- `dotfiles_update`: update dotfiles from GitHub (or configured repo source) and reload.

Profile helper:

```bash
dotfiles_profile show
dotfiles_profile full
dotfiles_profile light
dotfiles_profile minimal
dotfiles_profile reset
```

Profile settings are resolved in `~/.dotfiles_features` plus optional overrides in
`~/.dotfiles_features.local`.

## Dotfiles Self-Update

- Update checks run asynchronously during shell startup (non-blocking) when
  `DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK=true`.
- Default check scope is all interactive shells (`DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK_SCOPE=interactive`).
  Set it to `ssh` to check only in SSH sessions.
- Default throttle interval is 12 hours
  (`DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK_INTERVAL_SECONDS=43200`).
- When an update is detected, one message is shown per shell session:
  `Dotfiles update available: <local> -> <remote>. Run: dotfiles_update`

Repo resolution order for checks/updates:
1. `DOTFILES_REPO_DIR` (if set and valid)
2. `~/.dotfiles_repo_dir` (written by bootstrap by default)
3. `~/dotFiles`
4. `~/dotfiles`

`dotfiles_update` behavior:
- Uses writable local repo when available.
- If repo is missing or not writable, uses a temporary clone to install updates.
- Aborts if writable local repo has uncommitted changes.
- Calls bootstrap in non-interactive mode and then reloads the shell.

## Feature Highlights

- Prompt metadata and divider behavior are controlled by feature flags.
- Command duration tracking supports `auto|ps0|debug` via
  `DOTFILES_FEATURE_TRACK_COMMAND_DURATION_METHOD`.
- `PROMPT_COMMAND` is normalized to preserve existing hooks while adding:
  `capture_prompt_exit_status` and `do_my_checks`.
- `.env` auto-load/unload runs in prompt hooks: entering/leaving directories and
  editing the active `.env` both trigger reload/unload (toggle:
  `DOTFILES_FEATURE_AUTO_DOT_ENV`).
- Per-directory history switches to local `.bash_history` files when present
  (toggle: `DOTFILES_FEATURE_LOCAL_HISTORY`).
- History timestamps are controlled by `DOTFILES_FEATURE_HISTORY_TIMESTAMPS`.
- Dotfiles update checks are controlled by:
  `DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK`,
  `DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK_SCOPE`,
  `DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK_INTERVAL_SECONDS`.

## History Audit

Every prompt cycle can append audit records to a sibling file of your active
history file:

- Default: `~/.bash_history_audit`
- Format: `timestamp<TAB>user<TAB>exit<TAB>duration_us<TAB>command`

Inspect audit log:

```bash
audit_bash_history
audit_bash_history 100
```

## Completion Behavior

- Bash completion loader is sourced from common Linux/macOS paths.
- Homebrew completion paths are used only if `brew` exists.
- If full bash-completion is unavailable, Git completion is loaded from common
  fallback locations when possible.
- Git alias completion is registered dynamically for aliases that expand to
  `git ...`.
- Make target completion is enabled for `make` and `m`.

## Notable Functions

- `pull`: smart `git pull` based on tracked branch.
- `gfc <branch>`: fetch/checkout/reset hard to `origin/<branch>`.
- `server [port]`: starts `copyparty` in current directory (with periodic update checks).
- `hibp`: Have I Been Pwned password range check.
- `vimp path[:line]`: open Vim and jump to line.

## Local Customization Files

- `~/.path`: custom PATH additions.
- `~/.extra`: private machine/user customizations.
- `~/.systemspecific`: optional host-specific settings.
- `~/.dotfiles_features.local`: profile and feature overrides.

## Agent Notes

If you are automating changes in this repo, also read `AGENTS.md`.
