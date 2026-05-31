#!/bin/bash
WALLPAPER=$(awww query | grep -oP '(?<=image: ).*')

cat > /tmp/hyprlock-dynamic.conf << EOF
background {
    monitor =
    path = $WALLPAPER
    blur_passes = 3
    blur_size = 7
    brightness = 0.5
}
EOF

cat ~/.config/hypr/hyprlock-static.conf >> /tmp/hyprlock-dynamic.conf

hyprlock --config /tmp/hyprlock-dynamic.conf
