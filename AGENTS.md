# AI Agent Notes for This Dotfiles Repo

This document highlights behavior and conventions that matter for automation and
agent work. It is meant to save you from surprises when running commands.

## Entry Points and Load Order

The main shell entry point is `.bash_profile`, which sources config in this order:

`~/.path` → `.dotfiles_features` → `.bash_prompt` → `.exports` → `.functions` → `.extra` →
`.systemspecific` → `.aliases/bash/aliases`

Notes:
- `.bash_profile` first sources `.dotfiles_agent_guard`. When it detects a
  coding agent / harness (marker variables such as `CLAUDECODE`,
  `CODEX_SANDBOX*`, `CURSOR_AGENT`, `GEMINI_CLI`, `AGENT=...`) or a
  non-interactive shell, it takes the **agent load path** instead:
  `~/.path` → `.exports` → `.extra` → `.systemspecific` and nothing else. See
  "Agent Mode" below.
- `.bashrc` only sources `.bash_profile` for interactive shells.
- If you need custom PATH or private overrides, use `~/.path` and `~/.extra`.
- Feature toggles and profile defaults live in `~/.dotfiles_features`; optional
  machine-local overrides can be placed in `~/.dotfiles_features.local`.
- Safe mode can be entered with `BASH_SAFE_MODE="true"` or `safe_reload`.

## Agent Mode (what you most likely run in)

If you are a coding agent, the shells you spawn almost certainly land in agent
mode: `DOTFILES_AGENT` is exported (e.g. `claude-code`, `codex`, `cursor`,
`non-interactive`) and the environment is near-vanilla Bash:

- No aliases, no dotfiles functions, no completions, no custom prompt.
- No `PROMPT_COMMAND`, `PS0` or DEBUG-trap hooks: no `.env` auto-loading, no
  per-directory history switching, no history audit, no update notices, no
  terminal-title escape sequences on stdout.
- Default shopt settings (`nocaseglob`, `autocd`, `cdspell`, `globstar` are
  **not** enabled).
- `PAGER`, `GIT_PAGER`, `MANPAGER` default to `cat`; `CLICOLOR=0`.
- Only `~/.path`, `~/.exports`, `~/.extra`, `~/.systemspecific` are loaded
  (PATH, `EDITOR=nano`, history sizes, private per-machine settings).

Everything in "Behavior That Affects Automation" below therefore only applies
when the guard is disabled (`DOTFILES_AGENT_GUARD=false`), the agent is listed
in `DOTFILES_AGENT_GUARD_ALLOW_FULL`, or the harness starts an interactive
shell without any marker variable (e.g. Aider's `bash -i -c`). Do not "fix"
missing aliases/functions by sourcing `~/.bash_profile` with the guard
disabled; use `command`/full paths instead.

Guard knobs live in `.dotfiles_agent_guard` (env or
`~/.dotfiles_agent_guard.local`): `DOTFILES_AGENT_GUARD`, `DOTFILES_AGENT_MODE`,
`DOTFILES_AGENT_GUARD_NONINTERACTIVE`, `DOTFILES_AGENT_GUARD_EXTRA_MARKERS`,
`DOTFILES_AGENT_GUARD_ALLOW_FULL`. Trace decisions with `DOTFILES_DEBUG=true`.

## Behavior That Affects Automation

- **Auto-loads `.env`**: `.functions` loads/unloads `.env` when directory
  context changes and also reloads when the active `.env` file is edited. This
  can change environment variables unexpectedly.
- **Async dotfiles update checks**: interactive shells may start a background
  Git check (throttled by feature flags), and print a one-time-per-session
  notice when updates are available.
- **Per-directory Bash history**: if `.bash_history` exists in a directory, it
  becomes the active history file.
- **History audit log**: commands are also appended to `.bash_history_audit`
  alongside timestamp, user, exit code, and command duration (microseconds).
  The `user` field is sourced from `BASH_HISTORY_USERNAME` when present, which
  is expected to be injected by SSH via `authorized_keys`
  `environment="BASH_HISTORY_USERNAME=..."` entries. Preserve it across
  `sudo -i` and `sudo su` with
  `Defaults env_keep += "BASH_HISTORY_USERNAME"` in
  `/etc/sudoers.d/` (sample: `init/dotfiles-bash-history.sudoers`).
  `su -` / `sudo su -` are not covered because login-style `su` resets the
  environment. Use `audit_bash_history [N]` to inspect records.
- **Prompt hooks**: `PROMPT_COMMAND` can run checks after every command (exit
  status, timing, env/history checks), depending on feature flags.
- **Debug**: set `DOTFILES_DEBUG="true"` to log load steps.
- **Safe mode**: set `BASH_SAFE_MODE="true"` (or run `safe_reload`) to start a
  minimal shell that only loads `~/.path` and `~/.exports`. This skips the
  prompt, functions, aliases, completions, and PROMPT_COMMAND hooks. Use
  `reload` from safe mode to return to a full shell.
- **Agent mode**: entered automatically by `.dotfiles_agent_guard` (see
  above); `reload` from an interactive agent shell returns to a full shell
  with the guard disabled for that shell only.

## Feature Profiles and Hooks

- Profiles are selected with `DOTFILES_FEATURE_PROFILE` (`full`, `light`,
  `minimal`) and resolved in `.dotfiles_features`, then overridden by
  `.dotfiles_features.local`.
- Helper command: `dotfiles_profile [show|full|light|minimal|reset]`.
- Command-duration start hook method is controlled by
  `DOTFILES_FEATURE_TRACK_COMMAND_DURATION_METHOD` (`auto`, `ps0`, `debug`).
  `auto` prefers PS0 on supported Bash versions and falls back to DEBUG trap.

## Aliases and Functions

Aliases are modular and live under `.aliases/bash/`. The file
`.aliases/bash/aliases` loads category-specific alias files (git, docker, etc.).

Function loading is split:
- `.functions` is a loader.
- `.functions.internal.bash` contains internal runtime hooks/helpers.
- `.functions.external.bash` contains user-facing interactive function definitions.

High-impact functions in `.functions.external.bash`:
- `mkd` (mkdir + cd), `fs` (file/dir size)
- `pull` (smart git pull based on tracked branch)
- `f` (grep with ignore rules) and `q` (find with `.qignore`)
- `gfc` (git fetch/checkout/reset to origin branch)
- `vimp` (vim + optional line number parsing)
- `hibp` (Have I Been Pwned password check)
- `dotfiles_profile` (switch feature profiles)
- `dotfiles_update` (update dotfiles + reload shell)
- `audit_bash_history` (inspect command audit log)

High-impact reload helpers in `.functions.external.bash`:
- `reload` (full login shell reload)
- `safe_reload` (minimal/safe shell reload)
- `debug_reload` (reload with `DOTFILES_DEBUG=true`)

## Editors and Defaults

- Default `EDITOR` is **nano** (set in `.exports`).
- `.vimrc` exists, but is not the default editor.
- `.editorconfig` enforces UTF-8, LF line endings, and trimming whitespace.

## Git Configuration

There is a disabled git config: `.gitconfig.disabled`. It includes aliases,
color settings, and defaults (like `main` as the default branch). It is excluded
by the bootstrap script unless renamed.

## Install and Update

Use `source bootstrap.sh` from the repo root to install or update dotfiles.
It rsyncs to `$HOME` while excluding `.disabled`, scripts, and docs.
Use `set -- -f; source bootstrap.sh` to skip confirmation.
Bootstrap also attempts to install `bash-completion` when no loader script is
detected.

Bootstrap update-related env knobs:
- `DOTFILES_BOOTSTRAP_NO_SOURCE_PROFILE=true` skips `source ~/.bash_profile`.
- `DOTFILES_BOOTSTRAP_PERSIST_REPO_DIR=true|false` controls whether
  `~/.dotfiles_repo_dir` is written.

Dotfiles repo resolution order used by update checks and `dotfiles_update`:
1. `DOTFILES_REPO_DIR` (if set and valid git repo)
2. `~/.dotfiles_repo_dir`
3. `~/dotFiles`
4. `~/dotfiles`

## Other Notable Files

- `.dotfiles_agent_guard`: agent / non-interactive detection sourced first by
  `.bash_profile`; `.dotfiles_agent_guard.local.example` documents overrides
- `.inputrc`: readline completion and history settings
- `.tmux.conf`: tmux prefix and keybindings
- `.curlrc` / `.wgetrc`: networking defaults
- `.macos.disabled` / `.osx.disabled`: macOS settings (not applied on Linux)
- `.aliases/bash/git.aliases.bash`: Git alias source used by dynamic alias
  completion registration in `.bash_profile`
