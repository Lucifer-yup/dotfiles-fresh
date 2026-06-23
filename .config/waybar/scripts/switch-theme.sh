#!/bin/bash

THEME="$1"

cp ~/.config/waybar/themes/$THEME/config.jsonc \
  ~/.config/waybar/config.jsonc

cp ~/.config/waybar/themes/$THEME/style.css \
  ~/.config/waybar/style.css

cp ~/.config/waybar/themes/$THEME/colors.css \
  ~/.config/waybar/colors.css

pkill waybar
waybar &
