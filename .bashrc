#!/usr/bin/env bash
[[ $DOTFILES_DEBUG == "true" ]] && echo "[DOTFILE_DBG: Executing .BASHRC]"
# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

echo "export DISPLAY=:0" >> ~/.bashrc #for WSL1
[ -n "$PS1" ] && source ~/.bash_profile;
