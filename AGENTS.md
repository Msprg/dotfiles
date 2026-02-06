# AI Agent Notes for This Dotfiles Repo

This document highlights behavior and conventions that matter for automation and
agent work. It is meant to save you from surprises when running commands.

## Entry Points and Load Order

The main shell entry point is `.bash_profile`, which sources config in this order:

`~/.path` → `.bash_prompt` → `.exports` → `.functions` → `.extra` →
`.systemspecific` → `.aliases/bash/aliases`

Notes:
- `.bashrc` only sources `.bash_profile` for interactive shells.
- If you need custom PATH or private overrides, use `~/.path` and `~/.extra`.

## Behavior That Affects Automation

- **Auto-loads `.env`**: when you `cd` into a directory, `.functions` loads
  `.env` (and unloads the previous one). This can change environment variables
  unexpectedly.
- **Per-directory Bash history**: if `.bash_history` exists in a directory, it
  becomes the active history file.
- **Prompt hooks**: `PROMPT_COMMAND` is set to run checks after every command
  (exit status, timing, env/history checks).
- **Debug**: set `DOTFILES_DEBUG="true"` to log load steps.

## Aliases and Functions

Aliases are modular and live under `.aliases/bash/`. The file
`.aliases/bash/aliases` loads category-specific alias files (git, docker, etc.).

High-impact functions in `.functions`:
- `mkd` (mkdir + cd), `fs` (file/dir size)
- `pull` (smart git pull based on tracked branch)
- `f` (grep with ignore rules) and `q` (find with `.qignore`)
- `gfc` (git fetch/checkout/reset to origin branch)
- `vimp` (vim + optional line number parsing)
- `hibp` (Have I Been Pwned password check)

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

## Other Notable Files

- `.inputrc`: readline completion and history settings
- `.tmux.conf`: tmux prefix and keybindings
- `.curlrc` / `.wgetrc`: networking defaults
- `.macos.disabled` / `.osx.disabled`: macOS settings (not applied on Linux)

