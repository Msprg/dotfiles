# Dotfiles

Personal Bash-focused dotfiles with feature profiles, an always-on command
audit, and a guard that gives coding agents a clean, near-vanilla shell.

## Installation

Clone and install:

```bash
git clone https://github.com/Msprg/dotFiles.git
cd dotFiles
bash bootstrap.sh            # SYSTEM-WIDE install (default; uses sudo)
bash bootstrap.sh --user     # per-user install only
```

> **Muscle-memory note:** a plain `bash bootstrap.sh` (or `source bootstrap.sh`)
> now installs **system-wide** for all users. Pass `--user` for the old
> per-user behavior.

```
Usage: bash bootstrap.sh [--system|--user] [--migrate-user] [--force|-f] [--help]
  --system        install shared runtime for all users (default)
                  -> /usr/local/share/dotfiles + /etc/profile.d/dotfiles.sh + /var/log/dotfiles/audit
  --user          install for the invoking user only (~ + ~/.config/dotfiles)
  --migrate-user  with --system: back up and deactivate an existing per-user install
  --force, -f     skip the confirmation prompt
```

What a **system** install does:
- Rsyncs the runtime (`.config/dotfiles/` + `init/`) to
  `/usr/local/share/dotfiles` (root-owned, world-readable).
- Installs `/etc/profile.d/dotfiles.sh`, which loads the runtime in every Bash
  login shell — deliberately including non-interactive `bash -lc` shells, so
  agent shells get the agent guard and agent audit (see below). On
  Debian-family systems a marker block in `/etc/bash.bashrc` covers
  interactive non-login shells too.
- Creates the shared audit store `/var/log/dotfiles/audit` (root:root,
  mode 1733: everyone can write their own log, nobody can list or read
  others').
- Writes install metadata to `/usr/local/share/dotfiles/.dotfiles-install`
  (scope, install root, profile.d dir, source URL/branch, installed commit —
  suffixed `-dirty` for modified checkouts —, update mode, timestamp).

What a **user** install does:
- Rsyncs home dotfiles into `$HOME` and the runtime into `~/.config/dotfiles`
  (excludes `.git/`, `*.md`, `*.sh`, `*.disabled`, `tests/`, repo metadata).
- Migrates installs from older layouts (flat dotted files, dotted module
  dirs): moves `*.local` overrides into `~/.config/dotfiles`, removes the old
  repo-owned dotfiles from `$HOME`.
- Writes `.dotfiles-install` metadata and `~/.config/dotfiles/repo_dir` (the
  clone path, used by update checks).

Mixed scopes are detected: a `--user` install warns when a system-wide hook
exists (the hook loads first in login shells), and a `--system` install warns
when a per-user install is still active — run
`sudo bash bootstrap.sh --system --migrate-user` to back it up. Migration
moves **only files verified dotfiles-owned** to
`~/.dotfiles-user-install-backup-<timestamp>`, restores `/etc/skel` rc files,
and never touches `~/.extra`, `~/.systemspecific` or `*.local` overrides.

Bootstrap does **not** `git pull` any more: pull manually before re-running
it, or use `dotfiles_update` (below). It also ensures a Bash completion
loader is installed (best effort).

Bootstrap env knobs: `DOTFILES_SYSTEM_INSTALL_ROOT`,
`DOTFILES_SYSTEM_PROFILE_D_DIR`, `DOTFILES_SYSTEM_AUDIT_DIR`,
`DOTFILES_SYSTEM_BASHRC_FILE`, `DOTFILES_BOOTSTRAP_NO_SUDO`,
`DOTFILES_BOOTSTRAP_SKIP_COMPLETION`, `DOTFILES_BOOTSTRAP_NO_SOURCE_PROFILE`,
`DOTFILES_BOOTSTRAP_PERSIST_REPO_DIR`, `DOTFILES_BOOTSTRAP_REPO_DIR_VALUE`.

## Layout

Three variables describe an install:

| Variable | Meaning |
| --- | --- |
| `DOTFILES_HOME` | Runtime root: `/usr/local/share/dotfiles` (system) or `~/.config/dotfiles` (user). |
| `DOTFILES_LOCAL_HOME` | Per-user overrides, **always** `~/.config/dotfiles` (`features.local`, `agent_guard.local`, `repo_dir`) — even under a system install. |
| `DOTFILES_INSTALL_SCOPE` | `system` or `user` (set by the profile.d hook, default `user`). |

Only standard rc files and two private hooks live directly in `$HOME`:

- `~/.bashrc`, `~/.bash_profile`, `~/.inputrc`, `~/.vimrc`, `~/.tmux.conf`, ... (standard)
- `~/.bash_profile` is a ~10-line stub that sources
  `$DOTFILES_HOME/bash_profile` (guarded against double-loading) and carries
  the local-additions marker.
- `~/.systemspecific` (private, not in the repo): machine-specific settings,
  PATH additions and everything installers append; loaded early in every mode.
  If it exists, it matters.
- `~/.extra` (private, not in the repo): anything else you don't want to
  commit; loaded last so it can override.

Everything else lives in `$DOTFILES_HOME`, without leading dots:

| File | Purpose |
| --- | --- |
| `bash_profile` | the real runtime entry (full / safe / agent load paths) |
| `agent_guard` (+ `agent_guard.local`) | agent / non-interactive detection |
| `agent_audit` | agent-mode command recorder |
| `local_additions` | moves installer appends into `~/.systemspecific` |
| `path_defaults` | well-known tool dirs added to PATH when present |
| `features` (+ `features.local`) | feature flags and profiles |
| `prompt` | prompt |
| `exports` | environment exports |
| `functions`, `functions.internal.bash`, `functions.external.bash` | manifest loaders |
| `functions.internal.d/` | runtime modules: `00-common`, `10-history` (audit), `20-env`, `30-update`, `40-prompt` |
| `functions.external.d/` | user-facing modules: `10-core`, `20-dotfiles`, `30-filesystem`, `40-git`, `50-network-media` |
| `aliases/bash/` | modular aliases |
| `init/` | samples and hooks (sudoers snippet, Claude Code audit hook) |
| `.dotfiles-install` | install metadata written by bootstrap |

Per-user files in `$DOTFILES_LOCAL_HOME`: `features.local`,
`agent_guard.local`, `repo_dir` (user scope; path of the git clone).

The old `~/.path` file is retired; its content is absorbed into
`~/.systemspecific` automatically and the file deleted.

## Shell Load Order

Login shells enter via the `~/.bash_profile` stub (user scope) or
`/etc/profile.d/dotfiles.sh` (system scope); interactive non-login shells via
`~/.bashrc`, which sources `~/.bash_profile`. Both entry points share the
`_DOTFILES_RUNTIME_LOADED` guard, so the first one wins and the runtime loads
once per shell. `$D` below stands for `$DOTFILES_HOME`.

Full mode load order:
`$D/agent_guard` -> `$D/local_additions` -> `$D/path_defaults` -> `~/.systemspecific` -> `$D/features` -> `$D/prompt` -> `$D/exports` -> `$D/functions` -> `~/.extra` -> `$D/aliases/bash/aliases` -> PATH de-dup

`features` and `functions` are hard-required: if either is missing or fails to
source, the load aborts with an actionable error on stderr. The same applies
to every module the `functions` manifest chain loads
(`functions.internal.bash` -> `functions.internal.d/*.bash` ->
`functions.external.bash` -> `functions.external.d/*.bash`).

Safe mode (`BASH_SAFE_MODE=true`) loads only:
`$D/path_defaults`, `~/.systemspecific` and `$D/exports`

In safe mode, prompt/functions/aliases/completions/PROMPT_COMMAND hooks are skipped.

Agent mode (see below) loads only:
`$D/path_defaults` -> `~/.systemspecific` -> `$D/exports` -> `~/.extra` (+ `$D/agent_audit`)

## Local Additions and Installer PATH Lines

Tool installers (`claude`, `codex`, `cursor-agent`, `nvm`, `conda`, `rustup`,
`pnpm`, ...) either append `export PATH=...`/init lines to `~/.bashrc` or ask
you to. Two mechanisms make that work with these dotfiles:

- `$DOTFILES_HOME/path_defaults` (committed) prepends well-known per-user tool directories
  (`~/.local/bin`, `~/.cargo/bin`, `~/go/bin`, `~/.bun/bin`, `~/.deno/bin`,
  `~/.volta/bin`, `~/.npm-global/bin`, `~/.local/share/pnpm`, `~/.opencode/bin`,
  linuxbrew, `/snap/bin`, ...) whenever the directory exists, in every load
  path. Most installers therefore need no rc-file edit at all. Private entries
  go to `~/.systemspecific`, which is loaded right afterwards and wins.
- Both `~/.bashrc` and `~/.bash_profile` end with the marker
  `# >>> dotfiles: local additions below this line survive bootstrap/update >>>`.
  On user-scope installs, `$DOTFILES_HOME/local_additions` moves anything
  found below the marker into `~/.systemspecific` (which bootstrap never
  touches) at shell start and truncates the rc file back to the marker.
  Because `~/.systemspecific` is sourced later in the same load, the moved
  lines take effect immediately. The migration runs in the full and safe load
  paths (agent shells, which are frequent and short-lived, skip it; system
  installs skip it too — the shared runtime does not manage your rc files).
  Paragraphs already present in `~/.systemspecific` are not duplicated,
  concurrent shell starts are serialized with `flock`, and legacy rc files
  without the marker are handled (`bootstrap.sh` runs the same migration once
  before overwriting them). Override the target with
  `DOTFILES_LOCAL_ADDITIONS_FILE`.

Edits *above* the marker are still overwritten by bootstrap; put those in
`~/.systemspecific`, `~/.extra` or the repo. A leftover `~/.path` is absorbed
into `~/.systemspecific` and deleted.

## Agent / Non-Interactive Guard

Coding agents and harnesses (Claude Code, Codex CLI, Cursor, Gemini CLI, ...)
run commands through shells that read these dotfiles. `$DOTFILES_HOME/agent_guard`
is sourced first by the runtime `bash_profile` and switches to a near-vanilla
Bash when it detects such a caller:

- Known marker variables: `CLAUDECODE` / `CLAUDE_CODE_ENTRYPOINT` (Claude Code),
  `CODEX_SANDBOX` / `CODEX_SANDBOX_NETWORK_DISABLED` / `CODEX_THREAD_ID` /
  `CODEX_CI` (Codex CLI), `CURSOR_AGENT` (Cursor), `GEMINI_CLI` (Gemini CLI),
  `VSCODE_AGENT` / `COPILOT_AGENT` (VS Code Copilot agent mode), `CLINE_ACTIVE`
  (Cline), `AUGMENT_AGENT` (Augment), `GOOSE_TERMINAL` (Goose), `OPENCODE` /
  `OPENCODE_CLIENT` (OpenCode), `AGENT_CONTEXT_OUT` (Kiro), `PI_CODING_AGENT`
  (Pi), the generic `AGENT=<name>` / `AI_AGENT=<name>` conventions (Amp, Goose,
  Bun, Vercel detect-agent) and the `/opt/.devin` marker file.
- Any non-interactive shell that reads the runtime (`bash -lc`, cron,
  scripts). This also covers harnesses without a marker (Copilot CLI,
  Continue). Under a system install the profile.d hook runs for exactly these
  login shells too — deliberately, so agent `bash -lc` shells load the
  runtime and the guard routes them to the cheap agent path with the agent
  audit armed.

Agent mode:
- Loads `path_defaults`, `~/.systemspecific`, `exports`, `~/.extra` only.
- Skips prompt, feature flags, functions, aliases, completions, dotfiles
  `PROMPT_COMMAND` / `PS0` / DEBUG-trap hooks, terminal title, update checks,
  `set -b` and shopt tweaks (`nocaseglob`, `autocd`, `cdspell`, ...). The one
  hook it does install is the agent-audit recorder (see "Agent Command
  Audit").
- Fills in `PAGER`, `GIT_PAGER`, `MANPAGER` with `cat` when the harness left
  them unset (and replaces the `less -X` from `exports`), sets `CLICOLOR=0`.
- Exports `DOTFILES_AGENT=<name>` (e.g. `claude-code`, `codex`, `cursor`,
  `non-interactive`, `forced`) so scripts can tell.
- Defines `reload` to restart as a full login shell with the guard disabled.

Knobs (environment or `$DOTFILES_LOCAL_HOME/agent_guard.local`, see
`agent_guard.local.example`):

| Variable | Effect |
| --- | --- |
| `DOTFILES_AGENT_GUARD=false` | Disable the guard; one-shot, e.g. `DOTFILES_AGENT_GUARD=false claude` gives that agent the full environment. |
| `DOTFILES_AGENT_MODE=true` | Force agent mode for the shell (and its children). |
| `DOTFILES_AGENT_GUARD_NONINTERACTIVE=false` | Do not treat plain non-interactive shells as agents. |
| `DOTFILES_AGENT_GUARD_EXTRA_MARKERS='VAR[:name] ...'` | Extra marker variables. Without `:name` the variable's value (or lowercased name for `1`/`true`) is used as the agent name. |
| `DOTFILES_AGENT_GUARD_ALLOW_FULL='name ...'` | Detected agents that still get the full environment (e.g. `cursor cline`). |

`DOTFILES_AGENT_GUARD` and `DOTFILES_AGENT_MODE` are unset by the full/safe
load path so a shell where you disabled the guard does not silently disable it
for every agent launched from it. Use `DOTFILES_DEBUG=true` to trace the
decision.

## Runtime Controls

Quick shell reload helpers:
- `reload`: restart login shell in full mode.
- `safe_reload`: restart login shell in safe mode.
- `debug_reload`: restart login shell with `DOTFILES_DEBUG=true`.
- `dotfiles_update`: update the install from its recorded source and reload.

## Feature Profiles

The default profile is **minimal**: shared functions, aliases, completion and
exports, but no prompt automation, no `.env` auto-loading, no per-directory
history, no update checks. `light` and `full` layer automation on top.
The command audit is on in **every** profile (see "History Audit").

Precedence:
1. `DOTFILES_FEATURE_PROFILE` in the environment (validated:
   `minimal|light|full`; enables `DOTFILES_FEATURE_PROFILE=full bash -l`)
2. `$DOTFILES_LOCAL_HOME/features.local` (per-user, survives updates, applies
   on top of a shared system-wide install too — see `features.local.example`)
3. `minimal`

Individual feature flags are **not** read from the environment — only the
profile is; per-flag overrides (e.g. `DOTFILES_FEATURE_HISTORY_AUDIT=false`)
belong in `features.local`. `full` enables the async update check only for
user-scope installs.

Profile helper:

```bash
dotfiles_profile show
dotfiles_profile full
dotfiles_profile light
dotfiles_profile minimal
dotfiles_profile reset
```

Feature highlights:
- Prompt metadata and divider behavior are controlled by feature flags
  (`light`/`full`).
- Command duration tracking supports `auto|ps0|debug` via
  `DOTFILES_FEATURE_TRACK_COMMAND_DURATION_METHOD`.
- `PROMPT_COMMAND` is normalized to preserve existing hooks while adding
  the dotfiles hooks; in `minimal` only a lean audit hook is installed.
- `.env` auto-load/unload runs in prompt hooks (toggle:
  `DOTFILES_FEATURE_AUTO_DOT_ENV`).
- Per-directory history switches to local `.bash_history` files when present
  (toggle: `DOTFILES_FEATURE_LOCAL_HISTORY`); the audit log never moves with
  it.
- History timestamps are controlled by `DOTFILES_FEATURE_HISTORY_TIMESTAMPS`.
- Command auditing is controlled by `DOTFILES_FEATURE_HISTORY_AUDIT`
  (default `true` in all profiles).

## History Audit

Every prompt cycle of a full-mode (human) shell appends one fixed-width record
per command:

```
2026-08-31T21:04:11+0200  firstname.lastname        exit:0    took:1.2s      git status
```

Format: `timestamp  user  exit:N  took:D  command` (two-space-separated,
space-padded columns — not TSV). `took:` shows `-` unless duration tracking is
enabled; usernames longer than 24 characters are truncated.

**Where records go** — the audit path is independent of `HISTFILE`:
1. `DOTFILES_AUDIT_FILE`, if set (agent log: `DOTFILES_AGENT_AUDIT_FILE`).
2. System scope: `/var/log/dotfiles/audit/<identity>.log` — the shared store
   created by bootstrap (dir root:root mode 1733, files 0600 per user:
   everyone writes their own log, nobody can list or read others').
3. If the identity's file exists but belongs to someone else (e.g. `su` kept
   another user's environment): the account-named file in the same store —
   the identity still appears in the user column.
4. Legacy `~/.bash_history_audit` (the default for user-scope installs).

`<identity>` is `BASH_HISTORY_USERNAME` (sanitized: conservative charset, max
64 chars, rejected values fall back) or the account name. Old
`~/.bash_history_audit` files from previous installs are left frozen in
place; the viewer falls back to them with a notice when the current log is
empty.

**Audit identity**: `BASH_HISTORY_USERNAME` is intended for SSH setups that
inject an identity from `authorized_keys`:

```
environment="BASH_HISTORY_USERNAME=firstname.lastname" ssh-ed25519 ...
```

To preserve it across `sudo -i` and `sudo su`, install the sample sudoers
snippet (`Defaults env_keep += "BASH_HISTORY_USERNAME"`) from
`$DOTFILES_HOME/init/dotfiles-bash-history.sudoers` with
`visudo -f /etc/sudoers.d/dotfiles-bash-history`. Login-style `su -` /
`sudo su -` reset the environment and are not covered.

**Writer guarantees**: appends are serialized with `flock`; each history event
is audited once; an identical re-run (same user, exit code and command)
replaces the previous line in place, updating its timestamp/duration. A
DEBUG-trap assist closes the `HISTCONTROL=ignoreboth` gap: consecutive
re-runs of the same command **are** audited, each with its fresh exit code. A
leading space remains the intentional opt-out — space-prefixed commands are
never audited. If another tool claims the DEBUG trap, auditing degrades
gracefully to history-advance-only behavior.

Inspect the log:

```bash
audit_bash_history           # own log, numbered
audit_bash_history 100       # last 100 records
audit_bash_history -f        # follow
audit_bash_history -a        # agent log
audit_bash_history --all     # merged all-users view (root/sudo only)
audit_bash_history --all -f  # follow every log in the store
```

`--all` reads the shared store via `sudo` and merges all users' logs sorted by
timestamp; it is root/sudo-only by design.

**Log rotation** (optional): the store is plain append-only text. A logrotate
entry such as `/etc/logrotate.d/dotfiles-audit` with `copytruncate` (so open
shells keep writing to the same inode) works fine:

```
/var/log/dotfiles/audit/*.log {
    monthly
    rotate 12
    compress
    missingok
    notifempty
    copytruncate
}
```

**SELinux note**: `/var/log/dotfiles/audit` inherits `var_log_t`. Unconfined
users write fine; confined users may be denied and then silently fall back to
their `$HOME` file. Verify with `ls -Zd /var/log/dotfiles/audit`; if needed,
set a context with `semanage fcontext` and `restorecon`.

**Trust model (read before relying on this for security auditing)**: the store
is a `1733` directory where any local user may *create* files. The sticky bit
stops one user from deleting or overwriting another's existing `0600` log, but
before a given identity has ever written, another local user can pre-create
that identity's `<name>.log` (or `<name>.agent.log`). The victim's shell then
finds the name unwritable and silently falls back to `$HOME`, so a hostile
local user can **divert or pre-seed** another user's audit trail. This is an
accepted trade-off of keeping per-user files in a shared, unprivileged-writable
directory (chosen so the flock/dedupe writer can read back its own tail). It is
adequate when the local users are cooperating (one admin plus coding agents),
**not** a tamper-proof audit boundary against a hostile local account. For that,
move to root-owned files written by a privileged helper (a setuid or
sudoers-gated writer) — a larger change, tracked as a possible follow-up.

## Agent Command Audit

Agent-mode shells record what agents run into a separate agent log —
`/var/log/dotfiles/audit/<identity>.agent.log` (system scope) or
`~/.bash_history_audit_agent` (user scope; mode 600) — one record per line:

```
timestamp  user  agent  exit:N  took:D  command
```

- `bash -c` shells (Codex CLI `bash -lc "<cmd>"`, cron): one record per
  invocation with the full command string, exit code and duration, written
  from an EXIT trap.
- Interactive agent shells (Cursor/Cline/VS Code agent terminals, aider): one
  record per prompt via a `PROMPT_COMMAND` recorder, with exit code (no
  duration).
- Claude Code never reads rc files for its tool calls; install the PostToolUse
  hook `$DOTFILES_HOME/init/claude-code-audit-hook.sh` (instructions in the
  file header) to feed the same log from Claude Code itself.
- `user` comes from `BASH_HISTORY_USERNAME` like the regular audit; the same
  path-resolution chain and fallbacks apply.

Read it with `audit_bash_history -a [N|-f]` (all users: `-a --all`). Knobs
(env or `$DOTFILES_LOCAL_HOME/agent_guard.local`): `DOTFILES_AGENT_AUDIT=false`,
`DOTFILES_AGENT_AUDIT_FILE`, `DOTFILES_AGENT_AUDIT_MAX_CHARS` (default 4000).

## Dotfiles Self-Update

`$DOTFILES_HOME/.dotfiles-install`, written by bootstrap, is the primary
record of what is installed (scope, install root, source URL/branch,
installed commit, update mode).

- `dotfiles_update` clones the recorded source fresh into a temp dir and
  re-runs bootstrap with the installed scope (system installs update
  system-wide via sudo), then reloads the shell.
- Installs whose `update_mode` is `manual` (installed from a modified or
  non-tracking checkout) are protected: `dotfiles_update` refuses to replace
  them unless called as `dotfiles_update --remote`.
- Update checks run asynchronously during shell startup (non-blocking) when
  `DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK=true` (the `full` profile enables
  this for user-scope installs). One notice is shown per shell session:
  `Dotfiles update available: <local> -> <remote>. Run: dotfiles_update`
- The per-user check cache invalidates itself when the installed commit
  changes underneath it (e.g. another user updated a system install).
- Scope/throttle knobs: `DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK_SCOPE`
  (`interactive` default, or `ssh`),
  `DOTFILES_FEATURE_DOTFILES_UPDATE_CHECK_INTERVAL_SECONDS` (default 43200).

Repo resolution order for local-checkout checks (user scope):
1. `DOTFILES_REPO_DIR` (if set and valid)
2. `$DOTFILES_LOCAL_HOME/repo_dir` (written by bootstrap `--user`; legacy `~/.dotfiles_repo_dir` still read)
3. `~/dotFiles`
4. `~/dotfiles`

## Runtime Validation

```bash
bash tests/bash-runtime.sh
```

23 fixture-based checks (no root required): syntax of every runtime file,
loader wiring, agent/safe/full load paths, profile precedence, hook assembly,
bootstrap scopes and migration safety, update pipeline, and the audit
writer/viewer (dedupe, replace-in-place, truncation, DEBUG-trap capture).

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

- `~/.systemspecific`: host-specific settings and PATH additions (loaded early,
  every mode; installer appends and a legacy `~/.path` are moved here).
- `~/.extra`: private machine/user customizations (loaded last).
- `$DOTFILES_LOCAL_HOME/features.local`: profile and feature overrides.
- `$DOTFILES_LOCAL_HOME/agent_guard.local`: agent guard / audit overrides.

All of these are per-user and survive bootstrap and `dotfiles_update`, under
both install scopes.

## Agent Notes

If you are automating changes in this repo, also read `AGENTS.md`.
