#!/bin/bash

REPO_FILE="$HOME/.local/bin/repo-packages.txt"
AUR_FILE="$HOME/.local/bin/aur-packages.txt"

TMP_REPO="/tmp/repo-packages-new.txt"
TMP_AUR="/tmp/aur-packages-new.txt"

GIT_DIR="$HOME/.dotfiles-fresh/"
WORK_TREE="$HOME"

# Explicit official repo packages
comm -12 <(pacman -Qeq | sort) <(pacman -Slq | sort) >"$TMP_REPO"

# Explicit AUR packages
comm -23 <(pacman -Qeq | sort) <(pacman -Slq | sort) >"$TMP_AUR"

CHANGED=false

# Check repo packages
if ! diff -q "$TMP_REPO" "$REPO_FILE" >/dev/null 2>&1; then
  cp "$TMP_REPO" "$REPO_FILE"
  git --git-dir="$GIT_DIR" --work-tree="$WORK_TREE" add "$REPO_FILE"
  CHANGED=true
fi

# Check AUR packages
if ! diff -q "$TMP_AUR" "$AUR_FILE" >/dev/null 2>&1; then
  cp "$TMP_AUR" "$AUR_FILE"
  git --git-dir="$GIT_DIR" --work-tree="$WORK_TREE" add "$AUR_FILE"
  CHANGED=true
fi

# Commit and push only if something changed
if [ "$CHANGED" = true ]; then
  git --git-dir="$GIT_DIR" --work-tree="$WORK_TREE" commit -m "packages: $(date '+%Y-%m-%d %H:%M:%S')"
  git --git-dir="$GIT_DIR" --work-tree="$WORK_TREE" push
fi
