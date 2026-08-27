#!/usr/bin/env bash
[[ $DOTFILES_DEBUG == "true" ]] && echo "[DOTFILE_DBG: Executing .BASHRC]"
# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

[ -n "$PS1" ] && source ~/.bash_profile;

# Installers append PATH/init lines below this marker. At the next shell start
# ~/.dotfiles_local_additions moves them into ~/.systemspecific (which survives
# bootstrap/update and is loaded in full and agent mode). Do not edit above.
# >>> dotfiles: local additions below this line survive bootstrap/update >>>
