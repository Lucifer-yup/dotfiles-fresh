#!/bin/bash
if pgrep -f "python3.*widget.py" > /dev/null; then
    pkill -f "python3.*widget.py"
else
    cd ~/.config/ramwidget
    python3 widget.py &
fi
