# Testing the dotFiles runtime

Two tiers. The first is the baseline and always runs; the second is encouraged
for anything touching the command audit, identity resolution, privilege
escalation, or the system-scope bootstrap, but is **not** a hard requirement —
skip it when the host cannot run containers.

## 1. Runtime suite (required, no root, no Docker)

```sh
bash tests/bash-runtime.sh
```

Fixture-based, ~35 checks: syntax, loaders, feature profiles, prompt-hook
assembly, the audit writer/viewer, bootstrap scopes, migration safety, and the
update pipeline. Run it after any change under `.config/dotfiles/`,
`bootstrap.sh`, or the rc stubs. This is the minimum bar for a change to land.

Fast targeted loads while iterating (no install needed):

```sh
rt="$PWD/.config/dotfiles"
# interactive, default (minimal) profile
env -i PATH="$PATH" HOME="$(mktemp -d)" TERM=dumb DOTFILES_HOME="$rt" \
  bash --noprofile --rcfile .bash_profile -i
# agent path
env -i PATH="$PATH" HOME="$(mktemp -d)" DOTFILES_HOME="$rt" CLAUDECODE=1 \
  bash --noprofile --norc -c 'source .bash_profile; echo "$DOTFILES_AGENT"'
```

## 2. Docker multi-user SSH fixtures (encouraged, not required)

The audit trail's whole job is to attribute commands to the right person across
SSH logins, a shared account, and `sudo`/`su -`. That behaviour depends on real
PAM sessions (`/proc/self/sessionid`, `/proc/self/loginuid`), per-key
`authorized_keys environment=` injection, and separate Unix users — none of
which the runtime suite exercises. When you change any of:

- the audit identity / login-session map (`functions.internal.d/10-history.bash`,
  `agent_audit`, `init/claude-code-audit-hook.sh`),
- privilege-escalation handling (sudoers drop-in, `su -` recovery),
- the system-scope bootstrap / migration,

please also verify in throwaway containers that emulate a real multi-user host.
It is strongly encouraged but explicitly optional: **if the host has no Docker
(or no `AUDIT_*` capabilities, or no outbound network to pull base images), the
runtime suite above is a sufficient gate** — just say so in the PR/commit, and
note that identity-across-escalation was not exercised.

### Minimal shape to reproduce

Build an image from a base with `openssh-server sudo rsync git procps util-linux`,
create a few users (an admin in the sudo/wheel group, a plain user, and a shared
"deploy" account whose `~/.ssh/authorized_keys` carries two keys, each prefixed
`environment="BASH_HISTORY_USERNAME=<person>"`), install the sudoers env_keep and
`PermitUserEnvironment BASH_HISTORY_USERNAME` drop-ins, run `bootstrap.sh
--system`, and start `sshd -D`. Run the container with the audit capabilities so
sessionid/loginuid are real:

```sh
docker run -d --name dfx --cap-add AUDIT_CONTROL --cap-add AUDIT_WRITE \
  -p 127.0.0.1::22 <image>
```

Then drive it over real SSH (`ssh -i <key> -p <mapped-port> user@127.0.0.1`) and
check `/var/log/dotfiles/audit/*.log`.

### What to confirm

- **Identity across escalation.** A shared-account login via person A's key is
  audited as A; after `sudo -i` / `sudo su -` / `sudo -u other -i` the command
  is still attributed to A (recovered from the session map), not to `root`.
- **No forgery.** A different, hostile local user pre-creating a session-map
  file (`/run/dotfiles-audit/sessions/<id>`) must NOT change who an escalated
  shell is logged as — at worst it downgrades to the account name, never the
  attacker's chosen name.
- **No phantom re-audit.** A second login records only that session's commands,
  not the previous session's last command inherited via `~/.bash_history`.
- **Bootstrap as root.** Running `sudo bootstrap.sh --system` against a checkout
  owned by another user records a real `installed_commit` and
  `update_mode=remote` (not `unknown` / `manual`).
- **Prompt/timer under a real login.** With the `full` profile, the custom
  prompt survives the distro `~/.bashrc`, and a command's recorded duration is
  the command's own time, not idle time spent at the prompt.

Test both a Debian-family and an RHEL-family image where practical; the audit
store, `/etc/bash.bashrc` hook, and default groups differ between them.
