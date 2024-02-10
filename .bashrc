#!/usr/bin/env bash
[[ $DOTFILES_DEBUG == "true" ]] && echo "[DOTFILE_DBG: Executing .BASHRC]"
# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

[ -n "$PS1" ] && source ~/.bash_profile;
