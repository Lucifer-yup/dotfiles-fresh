#!/bin/bash

WALLPAPER_DIR="$HOME/Pictures"
STATE_FILE="/tmp/wallpaper_index"

TRANSITIONS=(
    "fade" "left" "right" "top" "bottom"
    "center" "outer" "wipe" "wave" "grow"
)

# Build sorted wallpaper list
mapfile -t WALLPAPERS < <(find "$WALLPAPER_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.webp" \) | sort)

TOTAL=${#WALLPAPERS[@]}
if [[ $TOTAL -eq 0 ]]; then
    echo "No wallpapers found in $WALLPAPER_DIR"
    exit 1
fi

# Read current index
INDEX=0
[[ -f "$STATE_FILE" ]] && INDEX=$(cat "$STATE_FILE")

# Go forward or backward based on argument
if [[ "$1" == "prev" ]]; then
    INDEX=$(( (INDEX - 1 + TOTAL) % TOTAL ))
else
    INDEX=$(( (INDEX + 1) % TOTAL ))
fi

echo "$INDEX" > "$STATE_FILE"

WALLPAPER="${WALLPAPERS[$INDEX]}"
TRANSITION="${TRANSITIONS[$RANDOM % ${#TRANSITIONS[@]}]}"
DURATION=$(awk -v min=1.5 -v max=3 'BEGIN{srand(); printf "%.1f", min+rand()*(max-min)}')

echo "[$INDEX/$((TOTAL-1))] $WALLPAPER ($TRANSITION)"

awww img "$WALLPAPER" \
    --transition-type "$TRANSITION" \
    --transition-duration "$DURATION" \
    --transition-fps 60
