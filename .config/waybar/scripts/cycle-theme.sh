#!/bin/bash
# Cycles through all themes in ~/.config/waybar/themes/
# State is persisted in ~/.config/waybar/.current-theme

THEMES_DIR="$HOME/.config/waybar/themes"
STATE_FILE="$HOME/.config/waybar/.current-theme"

# Collect themes alphabetically (picks up any new folders you add)
mapfile -t THEMES < <(ls -1 "$THEMES_DIR" | sort)

if [[ ${#THEMES[@]} -eq 0 ]]; then
    echo "No themes found in $THEMES_DIR"
    exit 1
fi

# Read current theme index from state file
CURRENT_INDEX=0
if [[ -f "$STATE_FILE" ]]; then
    CURRENT_THEME=$(cat "$STATE_FILE")
    for i in "${!THEMES[@]}"; do
        if [[ "${THEMES[$i]}" == "$CURRENT_THEME" ]]; then
            CURRENT_INDEX=$i
            break
        fi
    done
fi

# Advance to next theme (wraps around)
NEXT_INDEX=$(( (CURRENT_INDEX + 1) % ${#THEMES[@]} ))
NEXT_THEME="${THEMES[$NEXT_INDEX]}"

# Copy theme files
cp "$THEMES_DIR/$NEXT_THEME/config.jsonc" "$HOME/.config/waybar/config.jsonc"
cp "$THEMES_DIR/$NEXT_THEME/style.css"    "$HOME/.config/waybar/style.css"
cp "$THEMES_DIR/$NEXT_THEME/colors.css"   "$HOME/.config/waybar/colors.css"

# Save new state
echo "$NEXT_THEME" > "$STATE_FILE"

# Restart waybar
pkill waybar
waybar &

# Optional: notify which theme is now active
command -v notify-send &>/dev/null && \
    notify-send "Waybar" "Theme: $NEXT_THEME" --expire-time=2000
