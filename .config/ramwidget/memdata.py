# ~/.config/ramwidget/memdata.py

import os
import subprocess

# ── Name mapping ──────────────────────────────────────────────
PROCESS_GROUPS = {
    # Zen Browser
    "zen-bin": "Zen Browser", "WebExtensions": "Zen Browser",
    "Privileged": "Zen Browser", "Isolated": "Zen Browser",
    "RDD": "Zen Browser", "forkserver": "Zen Browser", "Web": "Zen Browser",
    "GMP": "Zen Browser",
    # Firefox
    "firefox": "Firefox", "firefox-bin": "Firefox",
    # Other browsers
    "chromium": "Chromium", "chrome": "Chrome", "brave": "Brave",
    # Terminal
    "kitty": "Kitty", "kitten": "Kitty",
    # Desktop
    "Hyprland": "Hyprland", "waybar": "Waybar", "swaync": "SwayNC",
    "rofi": "Rofi", "wofi": "Wofi", "dunst": "Dunst", "mako": "Mako",
    "swww-daemon": "SWWW", "hyprlock": "Hyprlock", "hypridle": "Hypridle",
    # Wayland / Display
    "Xwayland": "XWayland", "xdg-desktop-por": "XDG Portal",
    "xdg-document-por": "XDG Portal",
    # Audio
    "pipewire": "PipeWire", "pipewire-pulse": "PipeWire",
    "wireplumber": "WirePlumber",
    # System
    "systemd": "Systemd", "systemd-userwor": "Systemd",
    "systemd-journal": "Systemd", "systemd-logind": "Systemd",
    "systemd-resolve": "Systemd",
    "NetworkManager": "NetworkManager", "tailscaled": "Tailscale",
    "bluetoothd": "Bluetooth", "polkitd": "Polkit",
    # Dev
    "nvim": "Neovim", "vim": "Vim", "code": "VS Code",
    "node": "Node.js", "python": "Python", "python3": "Python",
    # Apps
    "discord": "Discord", "vesktop": "Vesktop", "spotify": "Spotify",
    "telegram-deskto": "Telegram", "obsidian": "Obsidian",
}

MIN_MB = 30  # processes below this go into Other

# ── Colours ───────────────────────────────────────────────────
APP_COLORS = {
    "Zen Browser":    "#f4a15d",
    "Firefox":        "#ff9500",
    "Chromium":       "#4a90d9",
    "Chrome":         "#4a90d9",
    "Brave":          "#fb542b",
    "Kitty":          "#80cbc4",
    "Hyprland":       "#b39ddb",
    "Waybar":         "#90caf9",
    "SwayNC":         "#ce93d8",
    "XWayland":       "#ef9a9a",
    "XDG Portal":     "#a5d6a7",
    "Tailscale":      "#4db6ac",
    "NetworkManager": "#ffcc80",
    "WirePlumber":    "#f48fb1",
    "PipeWire":       "#80deea",
    "Systemd":        "#bcaaa4",
    "Neovim":         "#66bb6a",
    "VS Code":        "#42a5f5",
    "Discord":        "#7986cb",
    "Vesktop":        "#7986cb",
    "Spotify":        "#66bb6a",
    "Obsidian":       "#9575cd",
    "Other":          "#546e7a",
}

FALLBACK_COLORS = [
    "#78909c", "#8d6e63", "#ff8a65",
    "#a1887f", "#90a4ae", "#ffe082", "#80cbc4",
]

def _color_for(name: str, index: int) -> str:
    return APP_COLORS.get(name, FALLBACK_COLORS[index % len(FALLBACK_COLORS)])


# ── System memory (ground truth) ──────────────────────────────
def get_system_memory() -> dict:
    info = {}
    with open("/proc/meminfo") as f:
        for line in f:
            key, val = line.split(":")
            info[key.strip()] = int(val.split()[0])  # kB

    total     = info["MemTotal"]
    available = info["MemAvailable"]
    used      = total - available

    return {
        "total_mb": total     // 1024,
        "used_mb":  used      // 1024,
        "free_mb":  available // 1024,
        "used_pct": round(used / total * 100, 1),
    }


# ── PSS per process (proportional, no double-counting) ────────
def _get_pss_kb(pid: str) -> int:
    """
    Read Pss from /proc/<pid>/smaps_rollup.
    PSS = each shared page divided by the number of processes sharing it.
    This means all process PSS values sum to actual physical RAM used.
    Falls back to 0 if unreadable (kernel threads, permission denied).
    """
    try:
        with open(f"/proc/{pid}/smaps_rollup") as f:
            for line in f:
                if line.startswith("Pss:"):
                    return int(line.split()[1])
    except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError):
        pass
    return 0


# ── Process identification via cmdline ────────────────────────
def _identify_process(pid: str, comm: str) -> str:
    """
    Read /proc/<pid>/cmdline for accurate app identification.
    cmdline contains the full binary path and args, null-byte separated.
    Falls back to PROCESS_GROUPS comm mapping if cmdline is unreadable.
    """
    try:
        cmdline = open(f"/proc/{pid}/cmdline").read().replace('\x00', ' ').strip().lower()
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        return PROCESS_GROUPS.get(comm, comm.capitalize())

    if not cmdline:
        return PROCESS_GROUPS.get(comm, comm.capitalize())

    # Match by binary path in cmdline — most reliable
    if "zen-browser" in cmdline or "zen-bin" in cmdline:
        return "Zen Browser"
    if "firefox" in cmdline:
        return "Firefox"
    if "chromium" in cmdline:
        return "Chromium"
    if "brave" in cmdline:
        return "Brave"
    if "/kitty" in cmdline or "/kitten" in cmdline:
        return "Kitty"
    if "discord" in cmdline or "vesktop" in cmdline:
        return "Discord/Vesktop"
    if "obsidian" in cmdline:
        return "Obsidian"
    if "spotify" in cmdline:
        return "Spotify"
    if "code" in cmdline and ("vscode" in cmdline or "visual-studio" in cmdline):
        return "VS Code"
    if "telegram" in cmdline:
        return "Telegram"
    if "steam" in cmdline:
        return "Steam"

    # Fall back to comm-based mapping
    return PROCESS_GROUPS.get(comm, comm.capitalize())


# ── Per-process PSS, grouped by app ───────────────────────────
def get_processes() -> list[dict]:
    """
    Enumerate all PIDs from /proc directly (faster than ps, no parsing issues).
    For each PID: read comm, identify app name via cmdline, read PSS.
    Group by app name and sum PSS — result is proportional, sums to ~Used.
    """
    groups: dict[str, int] = {}

    try:
        pids = [e for e in os.listdir("/proc") if e.isdigit()]
    except PermissionError:
        return []

    for pid in pids:
        # Read comm (process short name)
        try:
            comm = open(f"/proc/{pid}/comm").read().strip()
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue

        pss = _get_pss_kb(pid)
        if pss == 0:
            continue  # kernel thread or unreadable — skip

        name = _identify_process(pid, comm)
        groups[name] = groups.get(name, 0) + pss

    sorted_procs = sorted(groups.items(), key=lambda x: x[1], reverse=True)

    visible, other_kb = [], 0
    for i, (name, kb) in enumerate(sorted_procs):
        mb = kb // 1024
        if mb >= MIN_MB:
            visible.append({
                "name":  name,
                "mb":    mb,
                "kb":    kb,
                "color": _color_for(name, i),
            })
        else:
            other_kb += kb

    if other_kb > 0:
        visible.append({
            "name":     "Other",
            "mb":       other_kb // 1024,
            "kb":       other_kb,
            "color":    _color_for("Other", 0),
            "is_other": True,
        })

    return visible


# ── Combined snapshot ─────────────────────────────────────────
def get_snapshot() -> dict:
    return {
        "system":    get_system_memory(),
        "processes": get_processes(),
    }


# ── Self-test ─────────────────────────────────────────────────
if __name__ == "__main__":
    import time
    t0 = time.time()
    snap = get_snapshot()
    elapsed = time.time() - t0

    s = snap["system"]
    print(f"Total: {s['total_mb']} MB  |  Used: {s['used_mb']} MB  "
          f"|  Free: {s['free_mb']} MB  |  {s['used_pct']}%")
    print(f"(fetched in {elapsed:.2f}s)\n")

    proc_total = 0
    for p in snap["processes"]:
        bar = "▓" * (p["mb"] // 40)
        tag = " (other)" if p.get("is_other") else ""
        print(f"  {p['name']:<22} {p['mb']:>5} MB  {bar}{tag}")
        proc_total += p["mb"]

    print(f"\n  {'PSS sum':<22} {proc_total:>5} MB")
    print(f"  {'System used':<22} {s['used_mb']:>5} MB")
    print(f"  {'Delta':<22} {abs(proc_total - s['used_mb']):>5} MB  "
          f"({'over' if proc_total > s['used_mb'] else 'under'}count)")
