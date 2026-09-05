# AI Agent Notes for This Dotfiles Repo

This document highlights behavior and conventions that matter for automation and
agent work. It is meant to save you from surprises when running commands.

## Install Scopes and Variables

The runtime can be installed in two scopes; the repo keeps it under
`.config/dotfiles/` (de-dotted names):

| Variable | Meaning |
| --- | --- |
| `DOTFILES_HOME` | Runtime root: `/usr/local/share/dotfiles` (system scope, the bootstrap **default**) or `~/.config/dotfiles` (user scope). |
| `DOTFILES_LOCAL_HOME` | Per-user override dir, **always** `~/.config/dotfiles` (holds `features.local`, `agent_guard.local`, `repo_dir`) — even under a system install. |
| `DOTFILES_INSTALL_SCOPE` | `system` or `user`; set to `system` by the `/etc/profile.d` hook, defaults to `user`. |

Install metadata (scope, install root, source URL/branch/commit, update mode)
lives in `$DOTFILES_HOME/.dotfiles-install`; `dotfiles_update` reads it.

## Entry Points and Load Order

`~/.bash_profile` is a ~10-line stub: it sets `DOTFILES_HOME` and sources
`$DOTFILES_HOME/bash_profile`, guarded by `_DOTFILES_RUNTIME_LOADED` so the
runtime loads once per shell. Under a system install, `/etc/profile.d/dotfiles.sh`
does the same first (with `DOTFILES_INSTALL_SCOPE=system`); whichever entry
point runs first wins. `~/.bashrc` sources `~/.bash_profile` for interactive
shells; on Debian-family systems a marker block in `/etc/bash.bashrc` covers
interactive non-login shells.

`$DOTFILES_HOME/bash_profile` then takes one of three paths (`$D` =
`$DOTFILES_HOME`):

- **Full** (default): `$D/agent_guard` → `$D/local_additions` (user scope only) →
  `$D/path_defaults` → `~/.systemspecific` → `$D/features` → `$D/prompt` →
  `$D/exports` → `$D/functions` → `~/.extra` → `$D/aliases/bash/aliases` →
  PATH de-dup. `features` and `functions` are hard-required: a missing or
  failing file prints an actionable error to stderr and aborts the load.
- **Safe** (`BASH_SAFE_MODE=true` or `safe_reload`): `path_defaults`,
  `~/.systemspecific`, `exports` only.
- **Agent** (see below): `path_defaults` → `~/.systemspecific` → `exports` →
  `~/.extra`, plus `agent_audit`.

Notes:
- `agent_guard` runs first in every case. When it detects a coding agent /
  harness (marker variables such as `CLAUDECODE`, `CODEX_SANDBOX*`,
  `CURSOR_AGENT`, `GEMINI_CLI`, `AGENT=...`) or a non-interactive shell, the
  agent load path is taken.
- Under a **system install** the `/etc/profile.d` hook deliberately has **no
  interactivity guard**: it runs for all login shells, including the
  non-interactive `bash -lc` shells agents spawn — which is exactly how those
  shells get the agent guard and the agent audit.
- `~/.bashrc` and `~/.bash_profile` end with a marker line. On user-scope
  installs `local_additions` moves anything below it (installer PATH lines,
  nvm/conda init) into `~/.systemspecific` at shell start (full/safe paths
  only, never agent shells). `path_defaults` already adds the common tool dirs
  (`~/.local/bin`, `~/.cargo/bin`, `~/go/bin`, ...), so prefer not appending;
  if you must, append below the marker.
- Custom PATH or private overrides belong in `~/.systemspecific` (early) or
  `~/.extra` (late). Per-user feature overrides go in
  `$DOTFILES_LOCAL_HOME/features.local`; guard overrides in
  `$DOTFILES_LOCAL_HOME/agent_guard.local`.

## Agent Mode (what you most likely run in)

If you are a coding agent, the shells you spawn almost certainly land in agent
mode: `DOTFILES_AGENT` is exported (e.g. `claude-code`, `codex`, `cursor`,
`non-interactive`) and the environment is near-vanilla Bash:

- No aliases, no dotfiles functions, no completions, no custom prompt.
- No dotfiles prompt hooks: no `.env` auto-loading, no per-directory history
  switching, no update notices, no terminal-title escape sequences on stdout.
  The only hook agent mode installs is the agent-audit recorder: interactive
  agent shells get a small `PROMPT_COMMAND` entry, `bash -c` shells an EXIT
  trap (see below). No `PS0` or DEBUG-trap hooks.
- Default shopt settings (`nocaseglob`, `autocd`, `cdspell`, `globstar` are
  **not** enabled).
- `PAGER`, `GIT_PAGER`, `MANPAGER` default to `cat`; `CLICOLOR=0`.
- Only `path_defaults`, `~/.systemspecific`, `exports` and `~/.extra` are
  loaded (PATH, `EDITOR=nano`, history sizes, private per-machine settings
  and migrated installer lines).
- Your commands are recorded: `bash -c` invocations (exit code, duration,
  full command string, via EXIT trap) and interactive agent prompts (via
  `PROMPT_COMMAND`) go to the agent audit log —
  `/var/log/dotfiles/audit/<identity>.agent.log` on system installs, legacy
  `~/.bash_history_audit_agent` otherwise. Claude Code tool calls are recorded
  by the optional PostToolUse hook `$DOTFILES_HOME/init/claude-code-audit-hook.sh`.
  Disable with `DOTFILES_AGENT_AUDIT=false`.

Everything in "Behavior That Affects Automation" below therefore only applies
when the guard is disabled (`DOTFILES_AGENT_GUARD=false`), the agent is listed
in `DOTFILES_AGENT_GUARD_ALLOW_FULL`, or the harness starts an interactive
shell without any marker variable (e.g. Aider's `bash -i -c`). Do not "fix"
missing aliases/functions by sourcing `~/.bash_profile` with the guard
disabled; use `command`/full paths instead.

Guard knobs live in `agent_guard` (env or
`$DOTFILES_LOCAL_HOME/agent_guard.local`): `DOTFILES_AGENT_GUARD`,
`DOTFILES_AGENT_MODE`, `DOTFILES_AGENT_GUARD_NONINTERACTIVE`,
`DOTFILES_AGENT_GUARD_EXTRA_MARKERS`, `DOTFILES_AGENT_GUARD_ALLOW_FULL`.
Trace decisions with `DOTFILES_DEBUG=true`.

## Behavior That Affects Automation

The default profile is **minimal**: prompt hooks, `.env` auto-loading,
per-directory history and update checks are all **off** unless a user opted
into `light`/`full`. The command audit is on in every profile.

- **History audit log** (always on by default, all profiles): every prompt
  cycle of a full-mode shell appends a record —
  `timestamp  user  exit:N  took:D  command` (fixed-width columns, not TSV) —
  to `/var/log/dotfiles/audit/<identity>.log` (system scope; files 0600, dir
  1733) or `~/.bash_history_audit` (user scope). `identity`/`user` come from
  `BASH_HISTORY_USERNAME` when set (sanitized; intended to be injected by SSH
  `authorized_keys` `environment=` entries), else the account name. In the
  sticky shared store a shell writes only a file it owns (`fs.protected_regular`
  refuses appends to other users' files, root included), so an identity that
  names another local account — `sudo su` from that account — is recorded under
  the writer's account file (`root.log`) with the identity in the user column;
  nothing is ever `chown`ed away from its writer. The identity
  follows a user across privilege escalation two ways, both installed by a
  system-scope bootstrap: `Defaults env_keep += "BASH_HISTORY_USERNAME"` in
  `/etc/sudoers.d/` covers the `sudo` family, and a login-session map under
  `/run/dotfiles-audit/sessions/` (keyed on the immutable kernel audit session
  id `/proc/self/sessionid`, recreated each boot by a `tmpfiles.d` rule) covers
  env-scrubbing login shells (`su -`, `sudo su -`) that `env_keep` cannot; a
  session without any key identity seeds its account name (create-only), so
  `sudo su` shells of a password login still record who logged in. SSH
  injection of `BASH_HISTORY_USERNAME` needs
  `PermitUserEnvironment BASH_HISTORY_USERNAME` (sample drop-in
  `$DOTFILES_HOME/init/dotfiles-audit-sshd.conf`; admin-installed, not touched
  by bootstrap). A DEBUG-trap assist audits
  consecutive re-runs (which `HISTCONTROL=ignoreboth` hides from history) with
  fresh exit codes; a leading space still opts a command out. Inspect with
  `audit_bash_history [N|-f]`, agent log with `-a`, merged all-users view
  (root/sudo only) with `--all`. Opt out per user via
  `DOTFILES_FEATURE_HISTORY_AUDIT=false` in `features.local`.
- **Auto-loads `.env`** (`light`/`full` profiles): the functions runtime
  loads/unloads `.env` when directory context changes and reloads when the
  active `.env` file is edited. This can change environment variables
  unexpectedly.
- **Per-directory Bash history** (`light`/`full`): if `.bash_history` exists in
  a directory, it becomes the active history file. The audit log location is
  decoupled from this and never moves.
- **Async dotfiles update checks** (`full` profile, user scope only):
  interactive shells may start a background Git check and print a
  one-time-per-session notice when updates are available.
- **Prompt hooks**: `PROMPT_COMMAND` can run checks after every command (exit
  status, timing, env/history checks) in `light`/`full`; in `minimal` only a
  lean audit hook is installed.
- **Debug**: set `DOTFILES_DEBUG="true"` to log load steps.
- **Safe mode**: set `BASH_SAFE_MODE="true"` (or run `safe_reload`) to start a
  minimal shell that only loads `path_defaults`, `~/.systemspecific` and
  `exports`. Use `reload` from safe mode to return to a full shell.
- **Agent mode**: entered automatically by `agent_guard` (see above); `reload`
  from an interactive agent shell returns to a full shell with the guard
  disabled for that shell only.

## Feature Profiles and Hooks

- `minimal` (default) / `light` / `full`. Precedence: environment
  `DOTFILES_FEATURE_PROFILE` (validated) >
  `$DOTFILES_LOCAL_HOME/features.local` > `minimal`.
- Individual feature flags are **not** read from the environment — only the
  profile is; per-flag overrides belong in `features.local`.
- `DOTFILES_FEATURE_HISTORY_AUDIT` defaults to `true` in **all** profiles.
- Helper command: `dotfiles_profile [show|full|light|minimal|reset]`.
- Command-duration start hook method is controlled by
  `DOTFILES_FEATURE_TRACK_COMMAND_DURATION_METHOD` (`auto`, `ps0`, `debug`).
  `auto` prefers PS0 on supported Bash versions and falls back to DEBUG trap.

## Aliases and Functions

Aliases are modular and live under `$D/aliases/bash/`. The file
`aliases/bash/aliases` loads category-specific alias files (git, docker, etc.).

Function loading is a hard-required manifest chain — a missing or broken
module produces an actionable stderr message and a non-zero return:

- `functions` (loader) → `functions.internal.bash` → modules in
  `functions.internal.d/`: `00-common`, `10-history` (audit writer),
  `20-env`, `30-update`, `40-prompt`.
- then `functions.external.bash` → modules in `functions.external.d/`:
  `10-core` (incl. `audit_bash_history`), `20-dotfiles` (`dotfiles_profile`,
  `dotfiles_update`, `reload` helpers), `30-filesystem`, `40-git`,
  `50-network-media`.

High-impact functions: `mkd`, `fs`, `pull`, `f`/`q`, `gfc`, `vimp`, `hibp`,
`dotfiles_profile`, `dotfiles_update`, `audit_bash_history`, and the reload
helpers `reload` / `safe_reload` / `debug_reload`.

## Editors and Defaults

- Default `EDITOR` is **nano** (set in `$D/exports`).
- `.vimrc` exists, but is not the default editor.
- `.editorconfig` enforces UTF-8, LF line endings, and trimming whitespace.

## Git Configuration

There is a disabled git config: `.gitconfig.disabled`. It includes aliases,
color settings, and defaults (like `main` as the default branch). It is excluded
by the bootstrap script unless renamed.

## Install and Update

`bash bootstrap.sh [--system|--user] [--migrate-user] [--force|-f] [--help]`
(may also be sourced). **`--system` is the default**: runtime + `init/` +
metadata to `/usr/local/share/dotfiles`, hook to `/etc/profile.d/dotfiles.sh`,
audit dir `/var/log/dotfiles/audit` (root:root, mode 1733). `--user` rsyncs
the home stubs into `$HOME` and the runtime into `~/.config/dotfiles`, and
writes `$DOTFILES_LOCAL_HOME/repo_dir`. `--migrate-user` (system scope only)
backs up a previous per-user install — only files verified dotfiles-owned —
to `~/.dotfiles-user-install-backup-<timestamp>` and restores `/etc/skel` rc
files; `~/.extra`, `~/.systemspecific` and `*.local` files are never touched.
Bootstrap does **not** `git pull`; pull manually or use `dotfiles_update`.
Legacy flat/dotted layouts are migrated automatically on user-scope installs.

Knobs: `DOTFILES_SYSTEM_INSTALL_ROOT`, `DOTFILES_SYSTEM_PROFILE_D_DIR`,
`DOTFILES_SYSTEM_AUDIT_DIR`, `DOTFILES_SYSTEM_BASHRC_FILE`,
`DOTFILES_BOOTSTRAP_NO_SUDO`, `DOTFILES_BOOTSTRAP_SKIP_COMPLETION`,
`DOTFILES_BOOTSTRAP_NO_SOURCE_PROFILE`, `DOTFILES_BOOTSTRAP_PERSIST_REPO_DIR`,
`DOTFILES_BOOTSTRAP_REPO_DIR_VALUE`.

`dotfiles_update [--remote]` reads `$DOTFILES_HOME/.dotfiles-install`, clones
the recorded source fresh and re-runs bootstrap with the installed scope. It
refuses to replace `update_mode=manual` installs (modified/non-tracking
checkouts) unless `--remote` is given.

Dotfiles repo resolution order used by update checks (user scope):
1. `DOTFILES_REPO_DIR` (if set and a valid git repo)
2. `$DOTFILES_LOCAL_HOME/repo_dir` (legacy `~/.dotfiles_repo_dir` still honoured)
3. `~/dotFiles`
4. `~/dotfiles`

## Runtime Validation

`bash tests/bash-runtime.sh` — fixture-based checks (syntax, loaders, profiles,
bootstrap scopes, migration safety, update pipeline, audit writer/viewer), no
root required. Run it after changing anything under `.config/dotfiles/`,
`bootstrap.sh` or the rc stubs. See `TESTING.md` for the two testing tiers,
including the encouraged (but optional) Docker multi-user SSH fixtures for
changes to the audit identity, escalation handling, or system bootstrap.

## Other Notable Files

- `$D/agent_guard`: agent / non-interactive detection sourced first by
  `bash_profile`; `agent_guard.local.example` documents overrides
- `$D/agent_audit`: agent-mode command recorder (separate audit log)
- `$D/path_defaults`: well-known tool directories added to PATH when present
- `$D/local_additions`: moves installer appends from below the rc markers
  (and a legacy `~/.path`) into `~/.systemspecific` at shell start (user scope)
- `$D/init/claude-code-audit-hook.sh`: Claude Code PostToolUse hook feeding the
  agent audit log (installed with the runtime by bootstrap)
- `$D/init/dotfiles-bash-history.sudoers`: sudoers `env_keep` for
  `BASH_HISTORY_USERNAME` (bootstrap installs it after `visudo -c`)
- `$D/init/dotfiles-audit.tmpfiles.conf`: recreates the `/run` login-session
  identity map each boot (bootstrap installs it)
- `$D/init/dotfiles-audit-sshd.conf`: `PermitUserEnvironment` allowlist drop-in
  for SSH-injected identity (admin-installed)
- `.inputrc`: readline completion and history settings
- `.tmux.conf`: tmux prefix and keybindings
- `.curlrc` / `.wgetrc`: networking defaults
- `.macos.disabled` / `.osx.disabled`: macOS settings (not applied on Linux)
- `$D/aliases/bash/git.aliases.bash`: Git alias source used by dynamic alias
  completion registration in `bash_profile`
