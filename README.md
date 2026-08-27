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
`~/.path_defaults` -> `~/.path` -> `~/.dotfiles_features` -> `~/.bash_prompt` -> `~/.exports` -> `~/.functions` -> `~/.extra` -> `~/.systemspecific` -> `~/.aliases/bash/aliases`

Every load path (full, safe, agent) first moves installer appends from
`~/.bashrc` / `~/.bash_profile` into `~/.systemspecific` (see "Local Additions
and Installer PATH Lines") and finishes by de-duplicating `PATH`.

Function file split:
- `~/.functions` is a loader.
- `~/.functions.internal.bash` contains internal dotfiles runtime hooks/helpers.
- `~/.functions.external.bash` contains user-facing interactive function definitions.

Safe mode (`BASH_SAFE_MODE=true`) loads only:
`~/.path_defaults`, `~/.path` and `~/.exports`

In safe mode, prompt/functions/aliases/completions/PROMPT_COMMAND hooks are skipped.

Agent mode (see below) loads only:
`~/.path_defaults` -> `~/.path` -> `~/.exports` -> `~/.extra` -> `~/.systemspecific`

## Local Additions and Installer PATH Lines

Tool installers (`claude`, `codex`, `cursor-agent`, `nvm`, `conda`, `rustup`,
`pnpm`, ...) either append `export PATH=...`/init lines to `~/.bashrc` or ask
you to. Two mechanisms make that work with these dotfiles:

- `~/.path_defaults` (committed) prepends well-known per-user tool directories
  (`~/.local/bin`, `~/.cargo/bin`, `~/go/bin`, `~/.bun/bin`, `~/.deno/bin`,
  `~/.volta/bin`, `~/.npm-global/bin`, `~/.local/share/pnpm`, `~/.opencode/bin`,
  linuxbrew, `/snap/bin`, ...) whenever the directory exists, in every load
  path. Most installers therefore need no rc-file edit at all. Private entries
  still go to `~/.path`, which is loaded afterwards and wins.
- Both `~/.bashrc` and `~/.bash_profile` end with the marker
  `# >>> dotfiles: local additions below this line survive bootstrap/update >>>`.
  At every shell start `~/.dotfiles_local_additions` (sourced first by
  `~/.bash_profile`, in all modes) moves anything found below the marker into
  `~/.systemspecific`, which bootstrap never touches, and truncates the rc file
  back to the marker. Because `~/.systemspecific` is sourced later in the same
  load, the moved lines take effect immediately, in login shells (`bash -l`,
  Codex's `bash -lc`), interactive shells and agent mode alike; safe mode
  moves but does not load them. Paragraphs already present in
  `~/.systemspecific` are not duplicated, concurrent shell starts are
  serialized with `flock`, and legacy rc files without the marker are handled
  (`bootstrap.sh` runs the same migration once before overwriting them).
  Override the target with `DOTFILES_LOCAL_ADDITIONS_FILE`.

Edits *above* the marker are still overwritten by bootstrap; put those in
`~/.extra`, `~/.path`, `~/.systemspecific` or the repo.

## Agent / Non-Interactive Guard

Coding agents and harnesses (Claude Code, Codex CLI, Cursor, Gemini CLI, ...)
run commands through shells that read these dotfiles. `~/.dotfiles_agent_guard`
is sourced first by `~/.bash_profile` and switches to a near-vanilla Bash when
it detects such a caller:

- Known marker variables: `CLAUDECODE` / `CLAUDE_CODE_ENTRYPOINT` (Claude Code),
  `CODEX_SANDBOX` / `CODEX_SANDBOX_NETWORK_DISABLED` / `CODEX_THREAD_ID` /
  `CODEX_CI` (Codex CLI), `CURSOR_AGENT` (Cursor), `GEMINI_CLI` (Gemini CLI),
  `VSCODE_AGENT` / `COPILOT_AGENT` (VS Code Copilot agent mode), `CLINE_ACTIVE`
  (Cline), `AUGMENT_AGENT` (Augment), `GOOSE_TERMINAL` (Goose), `OPENCODE` /
  `OPENCODE_CLIENT` (OpenCode), `AGENT_CONTEXT_OUT` (Kiro), `PI_CODING_AGENT`
  (Pi), the generic `AGENT=<name>` / `AI_AGENT=<name>` conventions (Amp, Goose,
  Bun, Vercel detect-agent) and the `/opt/.devin` marker file.
- Any non-interactive shell that reads `~/.bash_profile` (`bash -lc`, cron,
  scripts). This also covers harnesses without a marker (Copilot CLI, Continue).

Agent mode:
- Loads `~/.path`, `~/.exports`, `~/.extra`, `~/.systemspecific` only.
- Skips prompt, feature flags, functions, aliases, completions,
  `PROMPT_COMMAND` / `PS0` / DEBUG-trap hooks, terminal title, update checks,
  `set -b` and shopt tweaks (`nocaseglob`, `autocd`, `cdspell`, ...).
- Fills in `PAGER`, `GIT_PAGER`, `MANPAGER` with `cat` when the harness left
  them unset (and replaces the `less -X` from `~/.exports`), sets `CLICOLOR=0`.
- Exports `DOTFILES_AGENT=<name>` (e.g. `claude-code`, `codex`, `cursor`,
  `non-interactive`, `forced`) so scripts can tell.
- Defines `reload` to restart as a full login shell with the guard disabled.
- Records agent commands to a separate audit file (see "Agent Command Audit").

Knobs (environment or `~/.dotfiles_agent_guard.local`, see
`.dotfiles_agent_guard.local.example`):

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

## Agent Command Audit

Agent-mode shells record what agents run into a separate file,
`~/.bash_history_audit_agent` (mode 600), one record per line:

```
timestamp  user  agent  exit:N  took:D  command
```

- `bash -c` shells (Codex CLI `bash -lc "<cmd>"`, cron): one record per
  invocation with the full command string, exit code and duration, written from
  an EXIT trap. No DEBUG trap is installed.
- Interactive agent shells (Cursor/Cline/VS Code agent terminals, aider): one
  record per prompt via `PROMPT_COMMAND` with exit code (no duration).
- Claude Code never reads rc files for its tool calls; install the PostToolUse
  hook `init/claude-code-audit-hook.sh` (instructions in the file header) to
  feed the same log from Claude Code itself.
- `user` comes from `BASH_HISTORY_USERNAME` like the regular audit.

Read it with `audit_bash_history -a [N|-f]`. Knobs (env or
`~/.dotfiles_agent_guard.local`): `DOTFILES_AGENT_AUDIT=false`,
`DOTFILES_AGENT_AUDIT_FILE`, `DOTFILES_AGENT_AUDIT_MAX_CHARS` (default 4000).

## History Audit

Every prompt cycle of a full-mode (human) shell can append audit records to a
sibling file of your active history file:

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

## Local Customization Files

- `~/.path`: custom PATH additions.
- `~/.extra`: private machine/user customizations.
- `~/.systemspecific`: optional host-specific settings.
- `~/.dotfiles_features.local`: profile and feature overrides.

## Agent Notes

If you are automating changes in this repo, also read `AGENTS.md`.
