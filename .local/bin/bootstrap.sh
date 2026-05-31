#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — Production-Grade Arch Linux Workstation Provisioning System
# =============================================================================
# Philosophy: "Safely converge the system toward the desired state while
#              surviving partial failures."
#
# Author : Lucifer <govindcj797@gmail.com>
# Rerun  : Safe — state-aware, idempotent, checkpoint-backed
# =============================================================================

set -uo pipefail
# NOTE: No global set -e. All failures are handled explicitly.

# ─── Hard Dependency Bootstrap (runs before logging, before everything) ───────
# git and base-devel are NOT present on a minimal Arch install.
# Install them unconditionally right here — no function, no checkpoint, no gate.
if ! pacman -Q git &>/dev/null; then
    echo "[BOOT] git not found — installing now..."
    sudo pacman -S --needed --noconfirm git || {
        echo "[BOOT] FATAL: Could not install git. Fix pacman/network first."
        exit 1
    }
fi
if ! pacman -Q base-devel &>/dev/null; then
    echo "[BOOT] base-devel not found — installing now..."
    sudo pacman -S --needed --noconfirm base-devel || {
        echo "[BOOT] FATAL: Could not install base-devel. Fix pacman/network first."
        exit 1
    }
fi

# ─── Persistent Logging ───────────────────────────────────────────────────────
LOG_FILE="$HOME/bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ─── Global Constants ─────────────────────────────────────────────────────────
readonly BOOTSTRAP_VERSION="2.0.0"
readonly STATE_DIR="$HOME/.local/state/bootstrap"
readonly DOTFILES_BACKUP="$HOME/.dotfiles-backup"
readonly DOTFILES_REPO="https://github.com/Lucifer-yup/dotfiles.git"
readonly DOTFILES_DIR="$HOME/.dotfiles"
readonly REPO_PKG_FILE="$HOME/.local/bin/repo-packages.txt"
readonly AUR_PKG_FILE="$HOME/.local/bin/aur-packages.txt"
readonly POST_REBOOT_SCRIPT="$HOME/.local/bin/post-reboot.sh"
readonly HYPR_AUTOSTART="$HOME/.config/hypr/modules/autostart.conf"
readonly LOCK_FILE="/tmp/bootstrap.lock"
readonly CHAOTIC_KEY="3056513887B78AEB"

# ─── Failure Tracking ─────────────────────────────────────────────────────────
declare -a FAILURES_FATAL=()
declare -a FAILURES_RECOVERABLE=()
declare -a FAILURES_WARNING=()
declare -a FAILURES_SKIPPED=()
declare -a SUCCESSES=()

# ─── Colors & UX ──────────────────────────────────────────────────────────────
# Detect terminal capability; degrade gracefully on plain TTY
if [[ -t 1 ]] && tput colors &>/dev/null && [[ $(tput colors) -ge 8 ]]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_DIM="\033[2m"
    C_GREEN="\033[1;32m"
    C_YELLOW="\033[1;33m"
    C_RED="\033[1;31m"
    C_CYAN="\033[1;36m"
    C_BLUE="\033[1;34m"
    C_MAGENTA="\033[1;35m"
    C_WHITE="\033[1;37m"
else
    C_RESET="" C_BOLD="" C_DIM="" C_GREEN="" C_YELLOW="" C_RED=""
    C_CYAN="" C_BLUE="" C_MAGENTA="" C_WHITE=""
fi

# ─── Logging Helpers ──────────────────────────────────────────────────────────
log_phase() {
    local msg="$1"
    echo ""
    echo -e "${C_CYAN}${C_BOLD}══════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}  ▶  ${msg}${C_RESET}"
    echo -e "${C_CYAN}${C_BOLD}══════════════════════════════════════════════════${C_RESET}"
    echo ""
}

log_info()    { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
log_ok()      { echo -e "${C_GREEN}[ OK ]${C_RESET}  $*"; }
log_warn()    { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
log_error()   { echo -e "${C_RED}[FAIL]${C_RESET}  $*"; }
log_skip()    { echo -e "${C_DIM}[SKIP]${C_RESET}  $*"; }
log_step()    { echo -e "${C_WHITE} ──▶ ${C_RESET}$*"; }

# ─── Failure Trackers ─────────────────────────────────────────────────────────
fail_fatal()       { log_error "$1"; FAILURES_FATAL+=("$1"); }
fail_recoverable() { log_error "$1"; FAILURES_RECOVERABLE+=("$1"); }
fail_warning()     { log_warn  "$1"; FAILURES_WARNING+=("$1"); }
fail_skip()        { log_skip  "$1"; FAILURES_SKIPPED+=("$1"); }
succeed()          { log_ok    "$1"; SUCCESSES+=("$1"); }

# ─── Retry Helper ─────────────────────────────────────────────────────────────
# Usage: retry <attempts> <delay_seconds> [--backoff] <command...>
retry() {
    local attempts="$1"; shift
    local delay="$1";    shift
    local backoff=0
    if [[ "${1:-}" == "--backoff" ]]; then
        backoff=1; shift
    fi
    local cmd=("$@")
    local current_delay="$delay"
    local attempt=1

    while (( attempt <= attempts )); do
        if "${cmd[@]}"; then
            return 0
        fi
        if (( attempt < attempts )); then
            log_warn "Attempt $attempt/$attempts failed for: ${cmd[*]}"
            log_info "Retrying in ${current_delay}s..."
            sleep "$current_delay"
            (( backoff )) && current_delay=$(( current_delay * 2 ))
        fi
        (( attempt++ ))
    done

    log_error "All $attempts attempts failed for: ${cmd[*]}"
    return 1
}

# ─── Checkpoint System ────────────────────────────────────────────────────────
checkpoint_set()   { mkdir -p "$STATE_DIR"; touch "$STATE_DIR/$1"; }
checkpoint_done()  { [[ -f "$STATE_DIR/$1" ]]; }
checkpoint_clear() { rm -f "$STATE_DIR/$1"; }

# Checkpoint names (reference — used via checkpoint_set/checkpoint_done/checkpoint_clear):
# chaotic_aur_configured | paru_installed | dotfiles_cloned | repo_packages_installed
# aur_packages_installed | services_enabled | desktop_entries_hidden
# post_reboot_generated  | reboot_pending   | post_reboot_completed

# ─── Sudo Keepalive ───────────────────────────────────────────────────────────
KEEPALIVE_PID=""

start_sudo_keepalive() {
    sudo -v
    ( while true; do sudo -n true; sleep 55; done ) &
    KEEPALIVE_PID=$!
    disown "$KEEPALIVE_PID" 2>/dev/null || true
    log_info "sudo keepalive started (PID: $KEEPALIVE_PID)"
}

stop_sudo_keepalive() {
    if [[ -n "$KEEPALIVE_PID" ]] && kill -0 "$KEEPALIVE_PID" 2>/dev/null; then
        kill "$KEEPALIVE_PID" 2>/dev/null || true
        log_info "sudo keepalive stopped"
    fi
    KEEPALIVE_PID=""
}

# ─── Cleanup & Interrupt Handler ──────────────────────────────────────────────
INTERRUPTED=0

cleanup() {
    local exit_code=$?
    stop_sudo_keepalive

    # Remove lockfile
    rm -f "$LOCK_FILE"

    # Kill any stale paru builds we may have started
    pkill -f "paru" 2>/dev/null || true

    # Remove temp files
    rm -f /tmp/ts-out.txt /tmp/bootstrap-tmp-* 2>/dev/null || true

    if (( INTERRUPTED )); then
        echo ""
        echo -e "${C_YELLOW}${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
        echo -e "${C_YELLOW}${C_BOLD}  Bootstrap interrupted. State preserved.${C_RESET}"
        echo -e "${C_YELLOW}  Re-run: bash ~/bootstrap.sh${C_RESET}"
        echo -e "${C_YELLOW}${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    else
        # Print full summary on normal exit
        print_summary
    fi

    # Flush logs
    sync
    return "$exit_code"
}

handle_interrupt() {
    INTERRUPTED=1
    echo ""
    log_warn "Interrupt received (Ctrl+C) — stopping gracefully..."
    exit 130
}

trap cleanup EXIT
trap handle_interrupt INT TERM

# ─── Lock File ────────────────────────────────────────────────────────────────
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
        if kill -0 "$pid" 2>/dev/null; then
            log_error "Another bootstrap instance is running (PID $pid)."
            log_error "If stale, remove: $LOCK_FILE"
            exit 1
        else
            log_warn "Stale lockfile found (PID $pid). Removing."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo "$$" > "$LOCK_FILE"
}

# ─── Environment Validation ───────────────────────────────────────────────────
validate_environment() {
    log_phase "Environment Validation"
    local ok=1

    # Arch Linux check
    if ! [[ -f /etc/arch-release ]]; then
        fail_fatal "Not running on Arch Linux (/etc/arch-release missing)"
        ok=0
    else
        succeed "Arch Linux detected"
    fi

    # systemd check
    if ! command -v systemctl &>/dev/null; then
        fail_fatal "systemd not found — this system is unsupported"
        ok=0
    else
        succeed "systemd available"
    fi

    # Internet connectivity
    if ! retry 3 5 curl -sf --max-time 10 https://archlinux.org &>/dev/null; then
        fail_fatal "No internet connectivity — bootstrap requires network access"
        ok=0
    else
        succeed "Internet connectivity verified"
    fi

    # Required base commands
    local required_cmds=(bash curl git sudo tee sed grep awk mkdir cp rm)
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            fail_fatal "Required command missing: $cmd"
            ok=0
        fi
    done
    (( ok )) && succeed "All required base commands present"

    # Wayland / Hyprland expectation (advisory only)
    if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${XDG_SESSION_TYPE:-}" ]]; then
        fail_warning "Wayland session not detected — running outside compositor"
    else
        succeed "Wayland environment detected"
    fi

    # Fatal failure gate
    if (( ${#FAILURES_FATAL[@]} > 0 )); then
        echo ""
        log_error "Fatal environment checks failed. Cannot continue:"
        for f in "${FAILURES_FATAL[@]}"; do
            echo -e "  ${C_RED}✗${C_RESET} $f"
        done
        exit 1
    fi
}

# ─── Summary Report ───────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}║         BOOTSTRAP SUMMARY REPORT                ║${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════════════╝${C_RESET}"
    echo ""

    if (( ${#SUCCESSES[@]} > 0 )); then
        echo -e "${C_GREEN}${C_BOLD}✔ Succeeded (${#SUCCESSES[@]})${C_RESET}"
        for s in "${SUCCESSES[@]}"; do
            echo -e "  ${C_GREEN}✓${C_RESET} $s"
        done
        echo ""
    fi

    if (( ${#FAILURES_SKIPPED[@]} > 0 )); then
        echo -e "${C_DIM}${C_BOLD}⊘ Skipped (${#FAILURES_SKIPPED[@]})${C_RESET}"
        for s in "${FAILURES_SKIPPED[@]}"; do
            echo -e "  ${C_DIM}○${C_RESET} $s"
        done
        echo ""
    fi

    if (( ${#FAILURES_WARNING[@]} > 0 )); then
        echo -e "${C_YELLOW}${C_BOLD}⚠ Warnings (${#FAILURES_WARNING[@]})${C_RESET}"
        for w in "${FAILURES_WARNING[@]}"; do
            echo -e "  ${C_YELLOW}△${C_RESET} $w"
        done
        echo ""
    fi

    if (( ${#FAILURES_RECOVERABLE[@]} > 0 )); then
        echo -e "${C_RED}${C_BOLD}✗ Recoverable Failures (${#FAILURES_RECOVERABLE[@]})${C_RESET}"
        for f in "${FAILURES_RECOVERABLE[@]}"; do
            echo -e "  ${C_RED}✗${C_RESET} $f"
        done
        echo ""
        echo -e "${C_YELLOW}${C_BOLD}Recovery suggestions:${C_RESET}"
        echo -e "  • Re-run this script: ${C_WHITE}bash ~/bootstrap.sh${C_RESET}"
        echo -e "  • Check log: ${C_WHITE}less ~/bootstrap.log${C_RESET}"
        echo -e "  • Skip to next phase: delete checkpoint in ${C_WHITE}~/.local/state/bootstrap/${C_RESET}"
        echo ""
    fi

    if (( ${#FAILURES_FATAL[@]} > 0 )); then
        echo -e "${C_RED}${C_BOLD}💀 Fatal Failures (${#FAILURES_FATAL[@]})${C_RESET}"
        for f in "${FAILURES_FATAL[@]}"; do
            echo -e "  ${C_RED}☠${C_RESET} $f"
        done
        echo ""
    fi

    if (( ${#FAILURES_RECOVERABLE[@]} == 0 && ${#FAILURES_FATAL[@]} == 0 )); then
        echo -e "${C_GREEN}${C_BOLD}🎉  Bootstrap completed successfully!${C_RESET}"
    else
        echo -e "${C_YELLOW}${C_BOLD}⚡  Bootstrap completed with issues. Review above.${C_RESET}"
    fi

    echo ""
    echo -e "${C_DIM}Full log: $LOG_FILE${C_RESET}"
    echo ""
}

# ─── Bootstrap Prerequisites ─────────────────────────────────────────────────
# git and base-devel are already guaranteed by the hard bootstrap at the top.
# This installs remaining soft dependencies: curl, wget, pacman-contrib.
bootstrap_prerequisites() {
    log_phase "Bootstrap Prerequisites"

    local prereqs=(curl wget pacman-contrib)
    local missing=()

    for pkg in "${prereqs[@]}"; do
        if ! pacman -Q "$pkg" &>/dev/null; then
            missing+=("$pkg")
        else
            log_info "Already installed: $pkg"
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        succeed "All prerequisites already present"
        return 0
    fi

    log_step "Installing missing prerequisites: ${missing[*]}"
    if ! retry 3 10 --backoff sudo pacman -S --needed --noconfirm "${missing[@]}"; then
        log_warn "Batch prereq install failed — retrying individually..."
        for pkg in "${missing[@]}"; do
            if ! retry 2 5 sudo pacman -S --needed --noconfirm "$pkg"; then
                fail_warning "Optional prerequisite failed: $pkg"
            fi
        done
    fi

    succeed "Prerequisites ready"
}

# ─── Chaotic-AUR Setup ────────────────────────────────────────────────────────
setup_chaotic_aur() {
    log_phase "Chaotic-AUR Configuration"

    if checkpoint_done "chaotic_aur_configured"; then
        log_skip "Chaotic-AUR already configured (checkpoint exists)"
        return 0
    fi

    # Check if already in pacman.conf to avoid duplicates
    if grep -q '^\[chaotic-aur\]' /etc/pacman.conf; then
        log_info "Chaotic-AUR repo already present in pacman.conf"
    else
        log_step "Importing Chaotic-AUR signing key..."
        if ! retry 5 10 --backoff sudo pacman-key --recv-key "$CHAOTIC_KEY" \
                --keyserver keyserver.ubuntu.com; then
            fail_recoverable "Failed to receive Chaotic-AUR key from keyserver"
            return 1
        fi

        if ! sudo pacman-key --lsign-key "$CHAOTIC_KEY"; then
            fail_recoverable "Failed to locally sign Chaotic-AUR key"
            return 1
        fi

        log_step "Installing Chaotic-AUR keyring..."
        if ! retry 3 5 sudo pacman -U --noconfirm \
            'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'; then
            fail_recoverable "Failed to install chaotic-keyring"
            return 1
        fi

        log_step "Installing Chaotic-AUR mirrorlist..."
        if ! retry 3 5 sudo pacman -U --noconfirm \
            'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'; then
            fail_recoverable "Failed to install chaotic-mirrorlist"
            return 1
        fi

        log_step "Appending [chaotic-aur] to /etc/pacman.conf..."
        printf '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist\n' \
            | sudo tee -a /etc/pacman.conf > /dev/null
    fi

    log_step "Syncing pacman databases..."
    if ! retry 3 10 --backoff sudo pacman -Syu --noconfirm; then
        fail_recoverable "pacman -Syu failed after Chaotic-AUR setup"
        return 1
    fi

    checkpoint_set "chaotic_aur_configured"
    succeed "Chaotic-AUR configured"
}

# ─── Paru Installation ────────────────────────────────────────────────────────
install_paru() {
    log_phase "AUR Helper — paru"

    if checkpoint_done "paru_installed"; then
        log_skip "paru checkpoint exists"
        if command -v paru &>/dev/null; then
            log_ok "paru already installed"
            return 0
        else
            log_warn "paru checkpoint set but binary missing — reinstalling"
            checkpoint_clear "paru_installed"
        fi
    fi

    if command -v paru &>/dev/null; then
        log_info "paru already installed — skipping"
        checkpoint_set "paru_installed"
        succeed "paru available"
        return 0
    fi

    log_step "Installing paru from Chaotic-AUR..."
    if ! retry 3 5 sudo pacman -S --needed --noconfirm paru; then
        # Fallback: build from source
        log_warn "Chaotic-AUR paru failed — attempting source build fallback"
        local tmp_dir
        tmp_dir=$(mktemp -d /tmp/bootstrap-tmp-XXXXX)

        if retry 3 10 git clone https://aur.archlinux.org/paru.git "$tmp_dir/paru"; then
            pushd "$tmp_dir/paru" > /dev/null || { rm -rf "$tmp_dir"; fail_recoverable "pushd failed for paru build dir"; return 1; }
            if makepkg -si --noconfirm; then
                popd > /dev/null || true
                rm -rf "$tmp_dir"
                checkpoint_set "paru_installed"
                succeed "paru installed from source"
                return 0
            fi
            popd > /dev/null || true
        fi
        rm -rf "$tmp_dir"
        fail_recoverable "paru installation failed — AUR packages will be skipped"
        return 1
    fi

    checkpoint_set "paru_installed"
    succeed "paru installed"
}

# ─── Dotfiles Restoration ─────────────────────────────────────────────────────
restore_dotfiles() {
    log_phase "Dotfiles Restoration"

    if checkpoint_done "dotfiles_cloned"; then
        log_skip "Dotfiles checkpoint exists"
        if [[ -d "$DOTFILES_DIR" ]]; then
            log_ok "Dotfiles already cloned"
        else
            log_warn "Dotfiles checkpoint set but repo missing — re-cloning"
            checkpoint_clear "dotfiles_cloned"
        fi
    fi

    # Git identity
    log_step "Configuring git identity..."
    git config --global user.name  "Lucifer"
    git config --global user.email "govindcj797@gmail.com"

    if ! checkpoint_done "dotfiles_cloned"; then
        if [[ -d "$DOTFILES_DIR" ]]; then
            log_info "Dotfiles repo directory already exists — skipping clone"
        else
            log_step "Cloning bare dotfiles repo..."
            if ! retry 3 10 --backoff git clone --bare "$DOTFILES_REPO" "$DOTFILES_DIR"; then
                fail_recoverable "Failed to clone dotfiles repo"
                return 1
            fi
        fi
        checkpoint_set "dotfiles_cloned"
        succeed "Dotfiles repo cloned"
    fi

    # Temporary dotfiles alias function (avoids alias export issues in scripts)
    dotfiles() { /usr/bin/git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" "$@"; }

    # Suppress untracked file noise
    dotfiles config --local status.showUntrackedFiles no

    # Conflict detection — find files that would be overwritten
    log_step "Detecting dotfile conflicts..."
    local conflicting_files=()
    while IFS= read -r line; do
        # git checkout outputs conflict lines like:
        #   error: The following untracked working tree files would be overwritten...
        #   <tab>filename
        [[ "$line" =~ ^$'\t'(.+)$ ]] && conflicting_files+=("${BASH_REMATCH[1]}")
    done < <(dotfiles checkout 2>&1 || true)

    if (( ${#conflicting_files[@]} > 0 )); then
        log_warn "Conflicting files detected — backing up to $DOTFILES_BACKUP"
        mkdir -p "$DOTFILES_BACKUP"

        for f in "${conflicting_files[@]}"; do
            local dest_dir
            dest_dir="$DOTFILES_BACKUP/$(dirname "$f")"
            mkdir -p "$dest_dir"
            if mv "$HOME/$f" "$dest_dir/" 2>/dev/null; then
                log_step "Backed up: $f"
            else
                log_warn "Could not back up: $f"
            fi
        done
    fi

    # Force overwrite known-safe shell init files
    for f in .bashrc .bash_profile; do
        if [[ -f "$HOME/$f" ]] && ! dotfiles ls-files --error-unmatch "$f" &>/dev/null; then
            log_step "Removing untracked $f before checkout"
            rm -f "$HOME/$f"
        fi
    done

    log_step "Checking out dotfiles..."
    if ! dotfiles checkout --force; then
        fail_recoverable "Dotfiles checkout failed even after conflict resolution"
        return 1
    fi

    succeed "Dotfiles restored"
}

# ─── Package Installation ─────────────────────────────────────────────────────
install_packages() {
    log_phase "Repository Package Installation"

    if checkpoint_done "repo_packages_installed"; then
        log_skip "Repo packages checkpoint exists — skipping"
    elif [[ ! -f "$REPO_PKG_FILE" ]]; then
        fail_warning "Repo package list not found: $REPO_PKG_FILE — skipping"
    else
        log_step "Batch installing repo packages..."
        if ! sudo bash -c "pacman -S --needed --noconfirm - < '$REPO_PKG_FILE'"; then
            log_warn "Batch install had failures — retrying packages individually..."
            local failed_pkgs=()
            while IFS= read -r pkg; do
                [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
                if ! retry 2 3 sudo pacman -S --needed --noconfirm "$pkg"; then
                    fail_recoverable "Package install failed: $pkg"
                    failed_pkgs+=("$pkg")
                fi
            done < "$REPO_PKG_FILE"
            if (( ${#failed_pkgs[@]} == 0 )); then
                succeed "All repo packages installed (via individual retry)"
            else
                fail_warning "Some repo packages could not be installed: ${failed_pkgs[*]}"
                log_warn "Recovery: sudo pacman -S --needed ${failed_pkgs[*]}"
            fi
        else
            succeed "All repo packages installed"
        fi
        checkpoint_set "repo_packages_installed"
    fi

    log_phase "AUR Package Installation"

    if checkpoint_done "aur_packages_installed"; then
        log_skip "AUR packages checkpoint exists — skipping"
    elif ! command -v paru &>/dev/null; then
        fail_skip "paru not available — skipping AUR packages"
    elif [[ ! -f "$AUR_PKG_FILE" ]]; then
        fail_warning "AUR package list not found: $AUR_PKG_FILE — skipping"
    else
        log_step "Batch installing AUR packages..."
        if ! paru -S --needed --noconfirm - < "$AUR_PKG_FILE"; then
            log_warn "Batch AUR install had failures — retrying individually..."
            while IFS= read -r pkg; do
                [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
                if ! retry 2 5 paru -S --needed --noconfirm "$pkg"; then
                    fail_recoverable "AUR package install failed: $pkg"
                    log_warn "Recovery: paru -S --needed $pkg"
                fi
            done < "$AUR_PKG_FILE"
        else
            succeed "All AUR packages installed"
        fi
        checkpoint_set "aur_packages_installed"
    fi
}

# ─── Service Management ───────────────────────────────────────────────────────
enable_service() {
    local unit="$1"
    # Check if the unit file is actually installed
    if ! systemctl list-unit-files --type=service | grep -q "^${unit}"; then
        fail_skip "Service unit not found: $unit (package not installed?)"
        return 1
    fi

    if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        log_info "Service already enabled: $unit"
    else
        if sudo systemctl enable --now "$unit"; then
            succeed "Service enabled & started: $unit"
        else
            fail_recoverable "Failed to enable service: $unit — Recovery: sudo systemctl enable --now $unit"
            return 1
        fi
    fi

    # Verify running state
    if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
        fail_warning "Service enabled but not active: $unit — check: journalctl -xeu $unit"
    fi
}

enable_services() {
    log_phase "System Services"

    if checkpoint_done "services_enabled"; then
        log_skip "Services checkpoint exists — skipping"
        return 0
    fi

    enable_service "sshd"
    enable_service "tailscaled"

    checkpoint_set "services_enabled"
}

# ─── Tailscale Setup ──────────────────────────────────────────────────────────
# Tailscale authentication requires a browser and a full GUI session.
# This phase only ensures the daemon is running; actual auth (tailscale up)
# is deferred to post-reboot.sh which runs inside Hyprland after GitHub SSH
# setup is complete.
setup_tailscale() {
    log_phase "Tailscale — Daemon Check"

    if ! command -v tailscale &>/dev/null; then
        fail_skip "tailscale binary not found — skipping"
        return 0
    fi

    # Ensure tailscaled is active so it's ready for post-reboot auth
    if ! systemctl is-active --quiet tailscaled 2>/dev/null; then
        log_step "Starting tailscaled daemon..."
        if sudo systemctl start tailscaled; then
            log_ok "tailscaled started"
        else
            fail_warning "tailscaled failed to start — Recovery: sudo systemctl start tailscaled"
        fi
    else
        log_info "tailscaled already running"
    fi

    # Check if already authenticated (e.g. re-run scenario)
    local ts_state
    ts_state=$(sudo tailscale status --json 2>/dev/null \
        | grep -oP '"BackendState"\s*:\s*"\K[^"]+' 2>/dev/null || echo "unknown")

    if [[ "$ts_state" == "Running" ]]; then
        log_ok "Tailscale already authenticated — skipping post-reboot auth step"
        succeed "Tailscale already connected"
    else
        log_info "Tailscale state: $ts_state"
        log_info "Authentication deferred to post-reboot (requires browser + GUI)"
        succeed "Tailscale daemon ready — auth will run after GitHub SSH setup"
    fi
}

# ─── SSH Setup ────────────────────────────────────────────────────────────────
setup_ssh() {
    log_phase "SSH Server"

    if ! command -v sshd &>/dev/null; then
        fail_skip "sshd not found — skipping SSH setup"
        return 0
    fi

    if ! systemctl is-active --quiet sshd 2>/dev/null; then
        if ! sudo systemctl start sshd; then
            fail_recoverable "Failed to start sshd — Recovery: sudo systemctl start sshd && sudo systemctl enable sshd"
            return 1
        fi
    fi

    # Verify it's actually listening
    if ss -tnlp 2>/dev/null | grep -q ':22 '; then
        succeed "SSH server running on port 22"
    else
        fail_warning "sshd started but not listening on port 22 — check: sudo sshd -T"
    fi
}

# ─── User Directories ─────────────────────────────────────────────────────────
setup_user_dirs() {
    log_phase "XDG User Directories"
    if command -v xdg-user-dirs-update &>/dev/null; then
        if xdg-user-dirs-update; then
            succeed "XDG user directories updated"
        else
            fail_warning "xdg-user-dirs-update failed"
        fi
    else
        fail_skip "xdg-user-dirs-update not found"
    fi
}

# ─── Flatpak Support ──────────────────────────────────────────────────────────
setup_flatpak() {
    log_phase "Flatpak Applications"

    if ! command -v flatpak &>/dev/null; then
        fail_skip "flatpak not installed — skipping"
        return 0
    fi

    # Ensure Flathub is configured
    if ! flatpak remote-list 2>/dev/null | grep -q "flathub"; then
        log_step "Adding Flathub remote..."
        if ! flatpak remote-add --if-not-exists flathub \
                https://dl.flathub.org/repo/flathub.flatpakrepo; then
            fail_recoverable "Failed to add Flathub remote — Recovery: flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
            return 1
        fi
        succeed "Flathub remote added"
    else
        log_info "Flathub already configured"
    fi

    # Install Stremio (foreground — runs after repo+AUR packages, before reboot)
    if flatpak list 2>/dev/null | grep -q "com.stremio.Stremio"; then
        log_skip "Stremio already installed"
    else
        log_step "Installing Stremio via Flatpak (this may take a while)..."
        if retry 2 10 flatpak install -y flathub com.stremio.Stremio; then
            succeed "Stremio installed"
        else
            fail_recoverable "Stremio install failed — Recovery: flatpak install -y flathub com.stremio.Stremio"
        fi
    fi
}

# ─── Desktop Entry Hiding ─────────────────────────────────────────────────────
hide_desktop_entries() {
    log_phase "Hiding Unwanted Desktop Entries"

    if checkpoint_done "desktop_entries_hidden"; then
        log_skip "Desktop entries already processed"
        return 0
    fi

    mkdir -p "$HOME/.local/share/applications"

    local entries=(
        avahi-discover bssh bvnc
        xgps xgpsspeed
        gcr-prompter gcr-viewer
        nautilus-autorun-software user-dirs-update-gtk
        org.freedesktop.Xwayland
        xdg-desktop-portal-gtk
        jconsole-java-openjdk jshell-java-openjdk java-java-openjdk
        rofi rofi-theme-selector
        qdbusviewer qv4l2 qvidcap
        io.elementary.granite-7.demo
        scrcpy-console
        org.gnupg.pinentry-qt5 org.gnupg.pinentry-qt
        electron37
    )

    local hidden_count=0
    local skipped_count=0

    for entry in "${entries[@]}"; do
        local src="/usr/share/applications/${entry}.desktop"
        local dest="$HOME/.local/share/applications/${entry}.desktop"

        if [[ ! -f "$src" ]]; then
            (( skipped_count++ ))
            continue
        fi

        # Skip if already correctly hidden (idempotent)
        if [[ -f "$dest" ]] && grep -q '^NoDisplay=true' "$dest" 2>/dev/null; then
            continue
        fi

        cp "$src" "$dest"
        # Remove existing NoDisplay lines, then add NoDisplay=true
        sed -i '/^NoDisplay/d' "$dest"
        printf 'NoDisplay=true\n' >> "$dest"
        (( hidden_count++ ))
        log_step "Hidden: $entry"
    done

    log_info "Hidden: $hidden_count entries | Not found (skipped): $skipped_count"
    checkpoint_set "desktop_entries_hidden"
    succeed "Desktop entry hiding complete"
}

# ─── Post-Reboot Script Generation ───────────────────────────────────────────
generate_post_reboot() {
    log_phase "Post-Reboot Script Generation"

    if checkpoint_done "post_reboot_generated"; then
        log_skip "Post-reboot script already generated"
        return 0
    fi

    mkdir -p "$(dirname "$POST_REBOOT_SCRIPT")"
    mkdir -p "$(dirname "$HYPR_AUTOSTART")"

    # ── Generate the report script (opens in its own Kitty window) ────────────
    local REPORT_SCRIPT="$HOME/.local/bin/post-reboot-report.sh"
    cat > "$REPORT_SCRIPT" << 'REPORTEOF'
#!/usr/bin/env bash
# post-reboot-report.sh — Final install summary. Self-deletes after display.

STATE_DIR="$HOME/.local/state/bootstrap"
REPORT_SCRIPT="$HOME/.local/bin/post-reboot-report.sh"
LOG_FILE="$HOME/bootstrap.log"

C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"
C_CYAN="\033[1;36m"; C_BLUE="\033[1;34m"; C_MAGENTA="\033[1;35m"
C_WHITE="\033[1;37m"

# Calculate total elapsed time
START_TIME=0
[[ -f "$STATE_DIR/start_time" ]] && START_TIME=$(cat "$STATE_DIR/start_time")
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
HOURS=$(( ELAPSED / 3600 ))
MINUTES=$(( (ELAPSED % 3600) / 60 ))
SECONDS=$(( ELAPSED % 60 ))

if (( HOURS > 0 )); then
    TIME_STR="${HOURS}h ${MINUTES}m ${SECONDS}s"
elif (( MINUTES > 0 )); then
    TIME_STR="${MINUTES}m ${SECONDS}s"
else
    TIME_STR="${SECONDS}s"
fi

clear
echo ""
echo -e "${C_MAGENTA}${C_BOLD}"
cat << 'BANNER'
  ██████╗ ███████╗██████╗  ██████╗ ██████╗ ████████╗
  ██╔══██╗██╔════╝██╔══██╗██╔═══██╗██╔══██╗╚══██╔══╝
  ██████╔╝█████╗  ██████╔╝██║   ██║██████╔╝   ██║
  ██╔══██╗██╔══╝  ██╔═══╝ ██║   ██║██╔══██╗   ██║
  ██║  ██║███████╗██║      ╚██████╔╝██║  ██║   ██║
  ╚═╝  ╚═╝╚══════╝╚═╝       ╚═════╝ ╚═╝  ╚═╝   ╚═╝
BANNER
echo -e "${C_RESET}"

echo -e "${C_CYAN}${C_BOLD}  ╔══════════════════════════════════════════════════════╗${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}  ║         WORKSTATION SETUP — COMPLETE REPORT         ║${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}  ╚══════════════════════════════════════════════════════╝${C_RESET}"
echo ""

# ── Timer display ──────────────────────────────────────────────────────────
echo -e "${C_WHITE}${C_BOLD}  ⏱  Total install time: ${C_GREEN}${TIME_STR}${C_RESET}"
echo -e "${C_DIM}     (bootstrap start → post-reboot complete)${C_RESET}"
echo ""

# ── Phase status (read checkpoint files) ──────────────────────────────────
echo -e "${C_WHITE}${C_BOLD}  Phase Summary${C_RESET}"
echo -e "${C_DIM}  ─────────────────────────────────────────────────────${C_RESET}"

declare -A PHASE_LABELS=(
    [chaotic_aur_configured]="Chaotic-AUR configured"
    [paru_installed]="paru AUR helper installed"
    [dotfiles_cloned]="Dotfiles restored"
    [repo_packages_installed]="Repo packages installed"
    [aur_packages_installed]="AUR packages installed"
    [services_enabled]="System services enabled"
    [desktop_entries_hidden]="Desktop entries cleaned"
    [post_reboot_generated]="Post-reboot automation generated"
    [post_reboot_completed]="Post-reboot setup complete"
)

PHASE_ORDER=(
    chaotic_aur_configured
    paru_installed
    dotfiles_cloned
    repo_packages_installed
    aur_packages_installed
    services_enabled
    desktop_entries_hidden
    post_reboot_generated
    post_reboot_completed
)

for phase in "${PHASE_ORDER[@]}"; do
    label="${PHASE_LABELS[$phase]}"
    if [[ -f "$STATE_DIR/$phase" ]]; then
        echo -e "  ${C_GREEN}✓${C_RESET}  $label"
    else
        echo -e "  ${C_YELLOW}○${C_RESET}  $label  ${C_DIM}(not completed)${C_RESET}"
    fi
done
echo ""

# ── Service status live check ──────────────────────────────────────────────
echo -e "${C_WHITE}${C_BOLD}  Service Status${C_RESET}"
echo -e "${C_DIM}  ─────────────────────────────────────────────────────${C_RESET}"
for svc in sshd tailscaled; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo -e "  ${C_GREEN}●${C_RESET}  $svc  ${C_GREEN}running${C_RESET}"
    else
        echo -e "  ${C_RED}●${C_RESET}  $svc  ${C_RED}not running${C_RESET}"
    fi
done
echo ""

# ── Tailscale status ───────────────────────────────────────────────────────
echo -e "${C_WHITE}${C_BOLD}  Network${C_RESET}"
echo -e "${C_DIM}  ─────────────────────────────────────────────────────${C_RESET}"
if command -v tailscale &>/dev/null; then
    TS_STATE=$(sudo tailscale status --json 2>/dev/null \
        | grep -oP '"BackendState"\s*:\s*"\K[^"]+' 2>/dev/null || echo "unknown")
    if [[ "$TS_STATE" == "Running" ]]; then
        TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
        echo -e "  ${C_GREEN}✓${C_RESET}  Tailscale connected  ${C_DIM}(${TS_IP})${C_RESET}"
    else
        echo -e "  ${C_YELLOW}△${C_RESET}  Tailscale: $TS_STATE  ${C_DIM}(run: sudo tailscale up)${C_RESET}"
    fi
else
    echo -e "  ${C_DIM}○${C_RESET}  Tailscale not installed"
fi
echo ""

# ── Log location ───────────────────────────────────────────────────────────
echo -e "${C_DIM}  Full bootstrap log: $LOG_FILE${C_RESET}"
echo -e "${C_DIM}  State dir:          $STATE_DIR${C_RESET}"
echo ""

echo -e "${C_GREEN}${C_BOLD}  🎉  Your Arch workstation is fully provisioned.${C_RESET}"
echo ""
echo -e "${C_YELLOW}  Press Enter to close...${C_RESET}"
read -r _

# Mark post-reboot fully complete and self-delete
touch "$STATE_DIR/post_reboot_completed"
rm -f "$REPORT_SCRIPT"
REPORTEOF
    chmod +x "$REPORT_SCRIPT"
    succeed "Report script generated: $REPORT_SCRIPT"

    # ── Generate post-reboot.sh ────────────────────────────────────────────────
    # NOTE: The heredoc uses 'POSTREBOOT' (quoted) so $HOME etc. do NOT expand
    # here — they expand at runtime inside the generated script, which is correct.
    cat > "$POST_REBOOT_SCRIPT" << 'POSTREBOOT'
#!/usr/bin/env bash
# =============================================================================
# post-reboot.sh — First-launch post-setup (runs once via Hyprland autostart)
# Self-removes after execution, then opens report terminal.
# =============================================================================

set -uo pipefail

HYPR_AUTOSTART="$HOME/.config/hypr/modules/autostart.conf"
POST_REBOOT_SCRIPT="$HOME/.local/bin/post-reboot.sh"
REPORT_SCRIPT="$HOME/.local/bin/post-reboot-report.sh"

C_RESET="\033[0m"; C_GREEN="\033[1;32m"; C_CYAN="\033[1;36m"
C_YELLOW="\033[1;33m"; C_WHITE="\033[1;37m"; C_BOLD="\033[1m"

log_ok()   { echo -e "${C_GREEN}[ OK ]${C_RESET}  $*"; }
log_info() { echo -e "${C_CYAN}[INFO]${C_RESET}  $*"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }

echo -e "${C_CYAN}${C_BOLD}"
echo "  ╔═══════════════════════════════════════╗"
echo "  ║      Post-Reboot Setup — Welcome      ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${C_RESET}"

# ── 1. Remove self + wallpaper one-shot from autostart immediately ─────────
if [[ -f "$HYPR_AUTOSTART" ]]; then
    sed -i '/post-reboot\.sh/d'     "$HYPR_AUTOSTART"
    sed -i '/random-wallpaper\.sh/d' "$HYPR_AUTOSTART"
    log_ok "Removed one-shot entries from Hyprland autostart"
fi

# ── 2. Set default browser to Zen Browser ─────────────────────────────────
log_info "Setting default browser to Zen Browser..."
if command -v xdg-settings &>/dev/null; then
    for zen_desktop in zen.desktop zen-browser.desktop io.github.zen_browser.zen.desktop; do
        if xdg-settings set default-web-browser "$zen_desktop" 2>/dev/null; then
            log_ok "Default browser set to: $zen_desktop"
            break
        fi
    done
else
    log_warn "xdg-settings not found — set default browser manually"
fi

# ── 3. Generate SSH key if missing ────────────────────────────────────────
SSH_KEY="$HOME/.ssh/id_ed25519"
if [[ ! -f "$SSH_KEY" ]]; then
    log_info "Generating SSH key (ed25519)..."
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -C "govindcj797@gmail.com" -f "$SSH_KEY" -N ""
    log_ok "SSH key generated: $SSH_KEY"
else
    log_info "SSH key already exists: $SSH_KEY"
fi

# ── 4. Print public key ───────────────────────────────────────────────────
echo ""
echo -e "${C_CYAN}${C_BOLD}  ── Your Public SSH Key ──────────────────────────────${C_RESET}"
cat "${SSH_KEY}.pub"
echo -e "${C_CYAN}  ──────────────────────────────────────────────────────${C_RESET}"
echo ""

# ── 5. Open GitHub SSH settings ───────────────────────────────────────────
log_info "Opening GitHub SSH settings in browser..."
if command -v xdg-open &>/dev/null; then
    xdg-open "https://github.com/settings/ssh/new" &
else
    log_warn "xdg-open not available — open manually: https://github.com/settings/ssh/new"
fi

echo ""
echo -e "${C_YELLOW}  Paste your public SSH key into GitHub, then press Enter here...${C_RESET}"
read -r _

# ── 6. Verify GitHub SSH authentication ───────────────────────────────────
log_info "Verifying GitHub SSH authentication..."
gh_result=$(ssh -T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    git@github.com 2>&1 || true)

if echo "$gh_result" | grep -q "successfully authenticated"; then
    log_ok "GitHub SSH authentication verified!"
else
    log_warn "GitHub SSH not yet verified:"
    echo "  $gh_result"
    echo -e "${C_YELLOW}  Retry: ssh -T git@github.com${C_RESET}"
    echo ""
    echo -e "${C_YELLOW}  Press Enter to continue anyway...${C_RESET}"
    read -r _
fi

# ── 7. Switch dotfiles remote from HTTPS → SSH ────────────────────────────
DOTFILES_DIR="$HOME/.dotfiles"
dotfiles() { /usr/bin/git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" "$@"; }

if [[ -d "$DOTFILES_DIR" ]]; then
    log_info "Switching dotfiles remote to SSH..."
    dotfiles remote set-url origin "git@github.com:Lucifer-yup/dotfiles.git"
    log_ok "Dotfiles remote updated to SSH"
fi

# ── 8. Tailscale authentication (GUI session available now) ───────────────
log_info "Starting Tailscale authentication..."

TS_STATE=$(sudo tailscale status --json 2>/dev/null \
    | grep -oP '"BackendState"\s*:\s*"\K[^"]+' 2>/dev/null || echo "unknown")

if [[ "$TS_STATE" == "Running" ]]; then
    log_ok "Tailscale already authenticated — skipping"
else
    TS_TMP=$(mktemp)
    sudo tailscale up 2>&1 | tee "$TS_TMP" &
    TS_PID=$!

    AUTH_URL=""
    WAIT=0
    while (( WAIT < 30 )); do
        sleep 1; (( WAIT++ ))
        AUTH_URL=$(grep -oP 'https://login\.tailscale\.com/\S+' "$TS_TMP" | head -1 || true)
        [[ -n "$AUTH_URL" ]] && break
        sudo tailscale status &>/dev/null && break
    done

    if [[ -n "$AUTH_URL" ]]; then
        log_info "Opening Tailscale auth URL in browser..."
        xdg-open "$AUTH_URL" &>/dev/null || true
        echo -e "${C_YELLOW}  Auth URL (fallback): $AUTH_URL${C_RESET}"
    fi

    wait "$TS_PID" 2>/dev/null || true
    rm -f "$TS_TMP"

    if sudo tailscale status &>/dev/null; then
        log_ok "Tailscale connected!"
    else
        log_warn "Tailscale not connected — Recovery: sudo tailscale up"
    fi
fi

# ── 9. Hand off to report terminal ────────────────────────────────────────
echo ""
echo -e "${C_GREEN}${C_BOLD}  Setup complete. Opening summary report...${C_RESET}"
echo ""
sleep 1

# Open the report in a fresh Kitty window, then close this one
if command -v kitty &>/dev/null && [[ -f "$REPORT_SCRIPT" ]]; then
    kitty --title "bootstrap-report" bash "$REPORT_SCRIPT" &
fi

# Self-delete this script
rm -f "$POST_REBOOT_SCRIPT"
POSTREBOOT

    chmod +x "$POST_REBOOT_SCRIPT"
    succeed "Post-reboot script generated: $POST_REBOOT_SCRIPT"

    # ── Inject both one-shot entries into autostart.conf ──────────────────────
    # Use the literal expanded path so there's no variable resolution ambiguity
    # when Hyprland reads the file.
    local wp_script="$HOME/.local/bin/random-wallpaper.sh"
    local wallpaper_line="exec-once = bash ${wp_script}"
    local postreboot_line="exec-once = kitty --title post-setup -e bash ${POST_REBOOT_SCRIPT}"

    # random-wallpaper: inject if not already there
    if grep -qF "random-wallpaper.sh" "$HYPR_AUTOSTART" 2>/dev/null; then
        log_info "random-wallpaper autostart entry already present"
    else
        printf '%s\n' "$wallpaper_line" >> "$HYPR_AUTOSTART"
        succeed "random-wallpaper one-shot injected into autostart.conf"
    fi

    # post-reboot terminal: inject if not already there
    if grep -qF "post-reboot.sh" "$HYPR_AUTOSTART" 2>/dev/null; then
        log_info "post-reboot autostart entry already present"
    else
        printf '%s\n' "$postreboot_line" >> "$HYPR_AUTOSTART"
        succeed "post-reboot autostart injected into autostart.conf"
    fi

    # Log what was written so it's visible in bootstrap.log for debugging
    log_info "autostart.conf now contains:"
    grep -E "random-wallpaper|post-reboot" "$HYPR_AUTOSTART" | while IFS= read -r line; do
        log_info "  $line"
    done

    checkpoint_set "post_reboot_generated"
}

# ─── Reboot Sequence ──────────────────────────────────────────────────────────
reboot_system() {
    log_phase "Reboot"

    if checkpoint_done "reboot_pending"; then
        log_info "Reboot was previously deferred — proceeding"
    fi

    echo ""
    echo -e "${C_YELLOW}${C_BOLD}  Bootstrap complete. A reboot is required.${C_RESET}"
    echo ""

    local countdown=10
    for (( i=countdown; i>0; i-- )); do
        printf "\r  ${C_CYAN}Rebooting in %2d seconds... (Ctrl+C to abort)${C_RESET}" "$i"
        sleep 1
    done
    echo ""

    checkpoint_set "reboot_pending"
    sync

    if command -v systemctl &>/dev/null; then
        sudo systemctl reboot
    else
        sudo reboot
    fi
}

# ─── Banner ───────────────────────────────────────────────────────────────────
print_banner() {
    echo ""
    echo -e "${C_MAGENTA}${C_BOLD}"
    echo "  ██████╗  ██████╗  ██████╗ ████████╗███████╗████████╗██████╗  █████╗ ██████╗ "
    echo "  ██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██╔══██╗"
    echo "  ██████╔╝██║   ██║██║   ██║   ██║   ███████╗   ██║   ██████╔╝███████║██████╔╝"
    echo "  ██╔══██╗██║   ██║██║   ██║   ██║   ╚════██║   ██║   ██╔══██╗██╔══██║██╔═══╝ "
    echo "  ██████╔╝╚██████╔╝╚██████╔╝   ██║   ███████║   ██║   ██║  ██║██║  ██║██║     "
    echo "  ╚═════╝  ╚═════╝  ╚═════╝    ╚═╝   ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     "
    echo -e "${C_RESET}"
    echo -e "${C_WHITE}${C_BOLD}  Arch Linux Workstation Provisioning System v${BOOTSTRAP_VERSION}${C_RESET}"
    echo -e "${C_DIM}  $(date '+%Y-%m-%d %H:%M:%S') | Log: $LOG_FILE${C_RESET}"
    echo ""
}

# ─── Main Entry Point ─────────────────────────────────────────────────────────
main() {
    print_banner
    acquire_lock
    start_sudo_keepalive

    # Create state directory and record start time for final report
    mkdir -p "$STATE_DIR"
    BOOTSTRAP_START_TIME=$(date +%s)
    echo "$BOOTSTRAP_START_TIME" > "$STATE_DIR/start_time"

    validate_environment
    bootstrap_prerequisites
    setup_chaotic_aur
    install_paru
    restore_dotfiles
    install_packages
    enable_services
    setup_ssh
    setup_tailscale
    setup_user_dirs
    setup_flatpak
    hide_desktop_entries
    generate_post_reboot

    # Summary is printed by cleanup trap on exit
    echo ""
    echo -e "${C_GREEN}${C_BOLD}  All phases complete.${C_RESET}"

    # Ask user whether to reboot now
    echo ""
    echo -n -e "${C_YELLOW}  Reboot now to complete setup? [Y/n] ${C_RESET}"
    read -r reboot_choice
    case "${reboot_choice,,}" in
        ""|y|yes) reboot_system ;;
        *)
            checkpoint_set "reboot_pending"
            log_info "Reboot deferred. Run 'systemctl reboot' when ready."
            ;;
    esac
}

main "$@"
