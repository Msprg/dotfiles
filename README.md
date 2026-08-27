# Dotfiles

Personal Bash-focused dotfiles with feature toggles for prompt behavior, command
timing, per-directory history, and `.env` auto-loading.

## Installation

Clone and install the shared runtime (Linux default):

```bash
git clone https://github.com/msprg/dotfiles.git
cd dotfiles
bash bootstrap.sh
```

The default installation:

- installs managed files under `/usr/local/share/dotfiles`;
- installs `/etc/profile.d/dotfiles.sh` for all interactive Bash users;
- uses the conservative `minimal` feature profile;
- keeps `~/.path`, `~/.extra`, `~/.systemspecific`, and
  `~/.dotfiles_features.local` as per-user overrides;
- records the installed commit and update source in
  `/usr/local/share/dotfiles/.dotfiles-install`.

To migrate an existing per-user dotFiles installation, back it up and deactivate
its shell entry points after installing the shared runtime:

```bash
bash bootstrap.sh --system --migrate-user
```

The backup is written to `~/.dotfiles-user-install-backup-<timestamp>`. User-local
override files are preserved. Without `--migrate-user`, bootstrap warns when a
legacy installation would continue to override the shared profile.

The previous per-user installation mode remains available explicitly:

```bash
bash bootstrap.sh --user
```

Use `--force` to skip confirmation. Bootstrap installs the checked-out files
exactly as they are; it no longer runs `git pull` implicitly. Bash completion is
installed on a best-effort basis.

## Shell Load Order

System installations enter through `/etc/profile.d/dotfiles.sh`, which sets
`DOTFILES_CONFIG_DIR=/usr/local/share/dotfiles` and sources the shared
`.bash_profile`. Per-user installations continue to enter through `~/.bashrc`.

Full mode load order:
`~/.path` -> shared `.dotfiles_features` -> shared `.bash_prompt` -> shared
`.exports` -> shared `.functions` -> `~/.extra` -> `~/.systemspecific` -> shared
`.aliases/bash/aliases`

Function file split below is relative to `$DOTFILES_CONFIG_DIR`:
- `.functions` is a loader.
- `.functions.internal.bash` loads ordered modules from `.functions.internal.d/`.
- `.functions.external.bash` loads ordered modules from `.functions.external.d/`.

Current module split:
- `.functions.internal.d/`: shared helpers, history, `.env`, update checks, prompt hooks
- `.functions.external.d/`: core helpers, dotfiles commands, filesystem tools, Git helpers, network/media helpers

The manifests use an explicit source order. Every listed module is required, and
a missing or invalid module aborts the full runtime load with an error on stderr.

Safe mode (`BASH_SAFE_MODE=true`) loads only the per-user `~/.path` and shared
`.exports`.

In safe mode, prompt/functions/aliases/completions/PROMPT_COMMAND hooks are skipped.

## Runtime Controls

Quick shell reload helpers:
- `reload`: restart login shell in full mode.
- `safe_reload`: restart login shell in safe mode.
- `debug_reload`: restart login shell with `DOTFILES_DEBUG=true`.
- `dotfiles_update`: update dotfiles from GitHub (or configured repo source) and reload.
- `DOTFILES_DEBUG_FIND=true`: print the `f` helper's generated grep command.

Profile helper:

```bash
dotfiles_profile show
dotfiles_profile full
dotfiles_profile light
dotfiles_profile minimal
dotfiles_profile reset
```

The shared `.dotfiles_features` provides defaults, then
`~/.dotfiles_features.local` selects a profile or overrides individual features.
`minimal` is the default. It disables prompt hooks, command timing, prompt
metadata, automatic `.env` loading, per-directory history switching, terminal
title changes, history timestamps, and automatic update polling.

## Dotfiles Self-Update

- Automatic update checks are disabled by default, including for shared installs.
- When explicitly enabled with `DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK=true`,
  checks run asynchronously during interactive shell startup.
- Default check scope is all interactive shells (`DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK_SCOPE=interactive`).
  Set it to `ssh` to check only in SSH sessions.
- Default throttle interval is 12 hours
  (`DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK_INTERVAL_SECONDS=43200`).
- When an update is detected, one message is shown per shell session:
  `Dotfiles update available: <local> -> <remote>. Run: dotfiles_update`

Update checks use `.dotfiles-install` metadata and compare the installed commit
with the configured remote branch. Installations made from a modified working
tree are marked `manual`, so they do not produce misleading update notices.
For safety, `dotfiles_update` will not replace such an installation unless
`dotfiles_update --remote` is requested explicitly.

`dotfiles_update` behavior:
- clones the configured remote branch into a temporary workspace;
- reinstalls that exact commit using the recorded `system` or `user` scope;
- updates the calling user's cache immediately and reloads the shell;
- requires sudo for shared installations;
- expires abandoned update locks after 15 minutes and invalidates stale per-user
  notices when the centrally installed commit changes.

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
- The runtime modules are sourced in an explicit order rather than discovered
  dynamically, which keeps startup overhead predictable while still making the
  codebase easier to navigate.

## History Audit

Every prompt cycle can append audit records to a sibling file of your active
history file:

- Default: `~/.bash_history_audit`
- Format: `timestamp<TAB>user<TAB>exit<TAB>duration_us<TAB>command`
- `user` comes from `BASH_HISTORY_USERNAME` when that variable is set; this is
  intended for SSH setups that inject an audit identity from `authorized_keys`,
  for example:
  `environment="BASH_HISTORY_USERNAME=firstname.lastname" ssh-ed25519 ...`
- To preserve that audit identity across `sudo -i` and `sudo su`, install the
  sample sudoers snippet from
  `init/dotfiles-bash-history.sudoers` with:
  `visudo -f /etc/sudoers.d/dotfiles-bash-history`
- `su -` and `sudo su -` are not covered by this setup because login-style
  `su` resets the environment.

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
- `vimp path:line:matching text`: open grep-style output at the matched line.

## Runtime Validation

Run `tests/bash-runtime.sh` from any directory to check module syntax, required
module failure handling, full/safe profile loading, and key helper behavior.

## Local Customization Files

- `~/.path`: custom PATH additions.
- `~/.extra`: private machine/user customizations.
- `~/.systemspecific`: optional host-specific settings.
- `~/.dotfiles_features.local`: profile and feature overrides.

## Agent Notes

If you are automating changes in this repo, also read `AGENTS.md`.
