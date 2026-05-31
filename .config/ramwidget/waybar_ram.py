#!/usr/bin/env python3
# Outputs a single line for waybar: e.g. "56.3%"

info = {}
for line in open("/proc/meminfo"):
    k, v = line.split(":")
    info[k.strip()] = int(v.split()[0])

total = info["MemTotal"]
used  = total - info["MemAvailable"]
pct   = used / total * 100

print(f"{pct:.1f}%")
