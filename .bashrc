#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

eval "$(starship init bash)"
alias ls='ls --color=auto'
alias grep='grep --color=auto'
alias dotfiles='/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME'
alias pinstall='sudo pacman -S $(pacman -Slq | fzf -m --preview "pacman -Si {}")'
export PATH="$HOME/.local/bin:$PATH"
PS1='[\u@\h \W]\$ '
