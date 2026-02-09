# shellcheck shell=bash
#about-alias 'docker compose abbreviations'

alias dco="docker compose"

# Defined in the `docker compose` plugin, please check there for details.
alias dcologs="docker compose logs -f --tail 100"
alias dcodown="docker compose down --remove-orphans"
alias dcou="docker compose up"
alias dcoupd="docker compose up -d"
alias dcoupfresh="docker compose up -d --force-recreate --remove-orphans"
alias dcouns="dcou --no-start"
alias dcops="dco ps"
