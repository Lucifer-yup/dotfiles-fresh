#!/bin/bash
STATE_FILE="$HOME/.config/waybar/.current-theme"
THEMES_DIR="$HOME/.config/waybar/themes"

if [[ -f "$STATE_FILE" ]]; then
  THEME=$(cat "$STATE_FILE")
  cp "$THEMES_DIR/$THEME/config.jsonc" "$HOME/.config/waybar/config.jsonc"
  cp "$THEMES_DIR/$THEME/style.css" "$HOME/.config/waybar/style.css"
  cp "$THEMES_DIR/$THEME/colors.css" "$HOME/.config/waybar/colors.css"
fi

pkill waybar
waybar &
