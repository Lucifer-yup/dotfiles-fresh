# Arch Linux Workstation Provisioning System

A resilient, state-aware, production-grade bootstrap for Arch Linux.

> "Safely converge the system toward the desired state while surviving partial failures."

The script is fully **idempotent** — run it as many times as needed. It detects completed phases via checkpoints and skips them. Partial failures never abort the entire run.

---

## Quick Bootstrap

On a fresh Arch install, run this single command:

```bash
curl -sL https://raw.githubusercontent.com/Lucifer-yup/dotfiles-fresh/master/.local/bin/bootstrap.sh | bash
```

Or download and review first (recommended):

```bash
curl -sL https://raw.githubusercontent.com/Lucifer-yup/dotfiles-fresh/master/.local/bin/bootstrap.sh -o bootstrap.sh
less bootstrap.sh
bash bootstrap.sh
```

The script handles everything through reboot automatically. After rebooting into Hyprland, a Kitty terminal titled **post-setup** opens automatically and completes the remaining steps.

---

## What the Bootstrap Does

| Phase | Task |
|-------|------|
| 1 | Environment validation (Arch, systemd, internet, required commands) |
| 2 | Configure Chaotic-AUR (keyring, mirrorlist, pacman.conf entry) |
| 3 | Install `paru` from Chaotic-AUR (falls back to source build) |
| 4 | Restore dotfiles via bare git repo (HTTPS, conflict-safe backup) |
| 5 | Batch install repo packages from `repo-packages.txt` |
| 6 | Batch install AUR packages from `aur-packages.txt` |
| 7 | Enable `sshd` + `tailscaled` services |
| 8 | Verify SSH server is listening |
| 9 | Authenticate Tailscale (opens auth URL automatically) |
| 10 | `xdg-user-dirs-update` |
| 11 | Install Stremio via Flatpak (configures Flathub if needed) |
| 12 | Hide junk `.desktop` entries from Rofi |
| 13 | Generate `post-reboot.sh` + inject into Hyprland autostart |
| 14 | Prompt to reboot with countdown |

### Post-Reboot (automatic, one-time)

On first Hyprland launch, Kitty opens titled **post-setup** and runs automatically:

| Step | Task |
|------|------|
| 1 | Removes itself from Hyprland autostart |
| 2 | Sets Zen Browser as default browser |
| 3 | Generates ed25519 SSH key (if missing) |
| 4 | Prints public key in terminal |
| 5 | Opens `github.com/settings/ssh/new` in browser |
| 6 | Waits for you to paste the key, then verifies GitHub SSH auth |
| 7 | Switches dotfiles remote from HTTPS → SSH |
| 8 | Runs `sudo tailscale up` (opens auth URL if needed) |
| 9 | Prints completion report, waits for Enter, then self-deletes |

---

## State & Checkpoints

Completed phases are tracked in:

```
~/.local/state/bootstrap/
```

Each phase creates a touchfile. On re-run, completed phases are skipped cleanly. To force a phase to re-run, delete its checkpoint:

```bash
# Example: re-run AUR package installation
rm ~/.local/state/bootstrap/aur_packages_installed

bash ~/bootstrap.sh
```

| Checkpoint file | Phase |
|-----------------|-------|
| `chaotic_aur_configured` | Chaotic-AUR repo setup |
| `paru_installed` | paru AUR helper |
| `dotfiles_cloned` | Bare dotfiles repo clone |
| `repo_packages_installed` | pacman packages |
| `aur_packages_installed` | AUR packages |
| `services_enabled` | sshd + tailscaled |
| `desktop_entries_hidden` | Rofi desktop entry cleanup |
| `post_reboot_generated` | post-reboot.sh generation |
| `reboot_pending` | Reboot has been requested |
| `post_reboot_completed` | Set by post-reboot.sh on completion |

---

## Resilience Behaviour

The script **never aborts on a single failure**. Each phase continues independently. Failures are categorized:

| Category | Meaning |
|----------|---------|
| `fatal` | Hard stop — only environment pre-checks |
| `recoverable` | Phase failed, skipped with recovery instructions |
| `warning` | Non-critical issue, proceeding anyway |
| `skipped` | Dependency missing, phase not attempted |

At the end, a **summary report** prints:

- Everything that succeeded
- Every failure with exact recovery commands
- Skipped phases with reasons

No vague "Google this" output — every failure tells you exactly what to run to fix it.

---

## Retry Behaviour

Network operations use a built-in retry wrapper with optional exponential backoff:

```
retry <attempts> <delay_seconds> [--backoff] <command>
```

Operations using retries:

| Operation | Attempts | Backoff |
|-----------|----------|---------|
| Chaotic-AUR keyserver | 5 | Yes |
| Chaotic-AUR package URLs | 3 | No |
| `pacman -Syu` | 3 | Yes |
| `git clone` (dotfiles, paru) | 3 | Yes |
| Internet connectivity check | 3 | No |
| Flatpak installs | 2 | No |

---

## Logging

All output — live terminal and background — is simultaneously logged to:

```
~/bootstrap.log
```

The log survives reboots and interruptions. If something went wrong, start here:

```bash
less ~/bootstrap.log
```

Or follow live during a re-run:

```bash
tail -f ~/bootstrap.log
```

---

## Interrupt Safety

Pressing `Ctrl+C` at any point:

- Stops gracefully (no half-written files)
- Preserves all checkpoint state
- Kills the sudo keepalive background process
- Cleans `/tmp` artifacts
- Prints an interruption summary

Re-running `bash ~/bootstrap.sh` after an interruption resumes from where it left off.

---

## Package Lists

Package sources are plain text files — one package per line, `#` for comments:

```
~/.local/bin/repo-packages.txt    # pacman packages
~/.local/bin/aur-packages.txt     # AUR packages (requires paru)
```

Packages are batch-installed first for speed. If the batch fails, each package is retried individually so one bad package doesn't block the rest. Failed packages are listed in the summary with recovery commands.

---

## Dotfiles

The dotfiles system uses a **bare git repo** at `~/.dotfiles` with the home directory as the work tree.

During bootstrap:

- Conflicts are detected before checkout
- Conflicting files are backed up to `~/.dotfiles-backup/` (preserving directory structure)
- Known shell init files (`.bashrc`, `.bash_profile`) are force-overwritten
- Untracked file noise is suppressed automatically

After the post-reboot phase, the remote is switched to SSH so you can push changes:

```bash
dotfiles push
```

The `dotfiles` alias is defined in your restored `.bashrc`.

---

## Chaotic-AUR

The bootstrap configures [Chaotic-AUR](https://aur.chaotic.cx/) before installing `paru`, which provides pre-built AUR binaries for faster installs.

If Chaotic-AUR's `paru` package fails for any reason, the script automatically falls back to cloning and building `paru` from the AUR source.

---

## Troubleshooting

**Bootstrap is already running / stale lock:**
```bash
rm /tmp/bootstrap.lock
bash ~/bootstrap.sh
```

**A specific phase failed and you want to retry it:**
```bash
# Find the checkpoint name from the table above, then:
rm ~/.local/state/bootstrap/<checkpoint_name>
bash ~/bootstrap.sh
```

**Dotfiles checkout left a mess:**
```bash
ls ~/.dotfiles-backup/    # your originals are here
```

**Tailscale not authenticated:**
```bash
sudo tailscale up
```

**SSH not listening:**
```bash
sudo systemctl status sshd
sudo journalctl -xeu sshd
```

**post-reboot.sh didn't run / ran but failed:**
```bash
bash ~/.local/bin/post-reboot.sh    # run it manually (if it still exists)
# or re-generate it:
rm ~/.local/state/bootstrap/post_reboot_generated
bash ~/bootstrap.sh
```

---

## File Locations

| Path | Purpose |
|------|---------|
| `~/bootstrap.sh` | Main provisioning script |
| `~/bootstrap.log` | Full persistent log |
| `~/.local/state/bootstrap/` | Checkpoint state files |
| `~/.local/bin/repo-packages.txt` | pacman package list |
| `~/.local/bin/aur-packages.txt` | AUR package list |
| `~/.local/bin/post-reboot.sh` | Post-reboot setup (auto-generated, self-deleting) |
| `~/.config/hypr/modules/autostart.conf` | Hyprland autostart (post-reboot injected here) |
| `~/.dotfiles/` | Bare dotfiles git repo |
| `~/.dotfiles-backup/` | Pre-checkout conflict backups |

---

## Final Notes

After full setup:

- Check audio (PipeWire)
- Test Bluetooth
- Verify Tailscale: `tailscale status`
- Test SSH access from another machine
- Push a dotfile change to confirm SSH remote is working: `dotfiles push`

Congratulations. Your workstation is now:
- resilient enough to survive being interrupted mid-install
- idempotent enough to run twice without breaking anything
- overengineered enough to log its own failures with recovery commands
- one rice away from becoming a full-time personality trait
